@tool
extends EditorPlugin

const ES_PREFIX := "auto_layout_switcher/"
const KEY_2D := ES_PREFIX + "layout_for_2d"
const KEY_3D := ES_PREFIX + "layout_for_3d"
const KEY_GAME := ES_PREFIX + "layout_for_game"
const KEY_ASSETLIB := ES_PREFIX + "layout_for_assetlib"
const KEY_SCRIPT := ES_PREFIX + "layout_for_script"
const KEY_FALLBACK := ES_PREFIX + "layout_fallback"

const DEF_2D := "Default"
const DEF_3D := "Default"
const DEF_GAME := "Default"
const DEF_ASSETLIB := "Default"
const DEF_SCRIPT := "Default"
const DEF_FALLBACK := "Default"

const MENU_NAMES := ["Editor Layouts", "Editor Layout", "Layouts"]
const VERBOSE := false
const SAVE_THROTTLE_MS := 1500

var _settings: EditorSettings
var _layouts_menu: PopupMenu
var _name_to_id: Dictionary = {}    # layout_name -> popup item id
var _applied_layout := ""
var _last_screen := ""
var _applying := false
var _last_save_ms := 0
var _hint_cached := ""

func _enter_tree() -> void:
	_settings = get_editor_interface().get_editor_settings()
	_register_editor_settings()
	if not main_screen_changed.is_connected(_on_main_screen_changed):
		main_screen_changed.connect(_on_main_screen_changed)
	await get_tree().process_frame
	_find_layouts_menu()
	_connect_menu_refresh()
	_refresh_layout_cache()
	_apply_for_current()

func _exit_tree() -> void:
	if main_screen_changed.is_connected(_on_main_screen_changed):
		main_screen_changed.disconnect(_on_main_screen_changed)
	if _layouts_menu and is_instance_valid(_layouts_menu):
		if _layouts_menu.menu_changed.is_connected(_on_layouts_menu_changed):
			_layouts_menu.menu_changed.disconnect(_on_layouts_menu_changed)
		if _layouts_menu.id_pressed.is_connected(_on_layouts_menu_activated):
			_layouts_menu.id_pressed.disconnect(_on_layouts_menu_activated)

# ---------- Settings helpers ----------

func _settings_notify() -> void:
	if not _settings:
		return
	if _settings.has_method("notify_property_list_changed"):
		_settings.notify_property_list_changed()
	elif _settings.has_method("property_list_changed_notify"):
		_settings.property_list_changed_notify()

func _es_get_str(key: String, def: String) -> String:
	if _settings and _settings.has_setting(key):
		var v := _settings.get_setting(key)
		var s := str(v)
		if s.length() > 0:
			return s
	return def

func _register_editor_settings() -> void:
	var props := [
		{"key": KEY_2D,       "def": DEF_2D},
		{"key": KEY_3D,       "def": DEF_3D},
		{"key": KEY_GAME,     "def": DEF_GAME},
		{"key": KEY_ASSETLIB, "def": DEF_ASSETLIB},
		{"key": KEY_SCRIPT,   "def": DEF_SCRIPT},
		{"key": KEY_FALLBACK, "def": DEF_FALLBACK},
	]
	for p in props:
		_settings.add_property_info({
			"name": p["key"],
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_ENUM_SUGGESTION,  # suggestions visible even if menu is empty
			"hint_string": "Default"
		})
		if not _settings.has_setting(p["key"]):
			_settings.set_setting(p["key"], p["def"])
	_settings_notify()

# ---------- Main signal ----------

func _on_main_screen_changed(screen_name: String) -> void:
	if _applying:
		return
	if screen_name == _last_screen:
		return
	_last_screen = screen_name
	_log("[AutoLayout] screen -> %s" % screen_name)
	var wanted := _layout_for(screen_name)
	if wanted.is_empty():
		return
	if _applied_layout == wanted:
		return
	_apply_layout_by_name(wanted)

# ---------- Selection ----------

func _layout_for(screen_name: String) -> String:
	match screen_name.to_lower():
		"2d":      return _es_get_str(KEY_2D, DEF_2D)
		"3d":      return _es_get_str(KEY_3D, DEF_3D)
		"game":    return _es_get_str(KEY_GAME, DEF_GAME)
		"assetlib":return _es_get_str(KEY_ASSETLIB, DEF_ASSETLIB)
		"script":  return _es_get_str(KEY_SCRIPT, DEF_SCRIPT)
		_:         return _es_get_str(KEY_FALLBACK, DEF_FALLBACK)

# ---------- Apply ----------

func _apply_for_current() -> void:
	var se := get_editor_interface().get_script_editor()
	if se and se.visible:
		var t := _es_get_str(KEY_SCRIPT, DEF_SCRIPT)
		if t != "" and _applied_layout != t:
			_apply_layout_by_name(t)
	else:
		var t := _es_get_str(KEY_FALLBACK, DEF_FALLBACK)
		if t != "" and _applied_layout != t:
			_apply_layout_by_name(t)

func _pick_valid_layout(preferred: String) -> String:
	if _name_to_id.has(preferred):
		return preferred
	if _name_to_id.has("Default"):
		return "Default"
	for k in _name_to_id.keys():
		var s := str(k).strip_edges()
		if s != "":
			return s
	return ""

func _apply_layout_by_name(layout_name: String) -> void:
	if layout_name.is_empty():
		return
	var valid := _pick_valid_layout(layout_name)
	if valid.is_empty():
		_log("[AutoLayout] No valid layout to apply.")
		return

	if _layouts_menu == null or not is_instance_valid(_layouts_menu):
		_find_layouts_menu()
		_connect_menu_refresh()
		if _layouts_menu == null:
			printerr("[AutoLayout] Layout menu not available. Cannot apply: %s" % valid)
			return

	if not _name_to_id.has(valid):
		_refresh_layout_cache()
	if not _name_to_id.has(valid):
		printerr("[AutoLayout] Layout '%s' not found. Known: %s" % [valid, str(_name_to_id.keys())])
		return

	var id := int(_name_to_id[valid])
	_log("[AutoLayout] applying layout: %s (id=%d)" % [valid, id])

	_applying = true
	if is_instance_valid(_layouts_menu):
		_layouts_menu.id_pressed.emit(id)
	_applying = false

	_applied_layout = valid
	_throttled_save()

	# Neutralize stale file paths that layouts may try to navigate to
	var ei := get_editor_interface()
	if ei and ei.has_method("get_file_system_dock"):
		var fsd := ei.get_file_system_dock()
		if fsd and fsd.has_method("navigate_to_path"):
			fsd.call_deferred("navigate_to_path", "res://")

# ---------- Menu setup ----------

func _find_layouts_menu() -> void:
	if _layouts_menu and is_instance_valid(_layouts_menu):
		return
	for menu_name in MENU_NAMES:
		var pm := _find_popup_by_name(get_tree().root, menu_name, false, true)
		if pm and _looks_like_layouts_menu(pm):
			_layouts_menu = pm
			break
		pm = _find_popup_by_name(get_tree().root, menu_name, true, true)
		if pm and _looks_like_layouts_menu(pm):
			_layouts_menu = pm
			break
	if _layouts_menu == null:
		_log("[AutoLayout] Layouts menu not found yet.")
	else:
		_log("[AutoLayout] Found layouts menu: %s" % _layouts_menu.name)

func _connect_menu_refresh() -> void:
	if _layouts_menu == null:
		return
	if not _layouts_menu.menu_changed.is_connected(_on_layouts_menu_changed):
		_layouts_menu.menu_changed.connect(_on_layouts_menu_changed)
	if not _layouts_menu.id_pressed.is_connected(_on_layouts_menu_activated):
		_layouts_menu.id_pressed.connect(_on_layouts_menu_activated)

func _on_layouts_menu_changed() -> void:
	_refresh_layout_cache()

func _on_layouts_menu_activated(id: int) -> void:
	if _layouts_menu == null:
		return
	var idx := _layouts_menu.get_item_index(id)
	if idx < 0 or _layouts_menu.is_item_separator(idx):
		return
	var label := _layouts_menu.get_item_text(idx)
	if label.length() > 0 and _name_to_id.has(label):
		_applied_layout = label
		_log("[AutoLayout] user applied layout -> %s" % _applied_layout)

# ---------- Menu scan ----------

func _find_popup_by_name(node: Node, wanted: String, descend_into_items: bool, tolerant: bool) -> PopupMenu:
	if node == null:
		return null
	if node is PopupMenu:
		var pm := node as PopupMenu
		var n := pm.name
		if n == wanted or (tolerant and n.to_lower().find(wanted.to_lower()) != -1):
			return pm
		if descend_into_items:
			for i in range(pm.item_count):
				var label := pm.get_item_text(i)
				if label == wanted or (tolerant and label.to_lower().find(wanted.to_lower()) != -1):
					var sub := pm.get_item_submenu_node(i)
					if sub:
						return sub
				var maybe := pm.get_item_submenu_node(i)
				if maybe:
					var found := _find_popup_by_name(maybe, wanted, true, tolerant)
					if found:
						return found
	for child in node.get_children():
		var res := _find_popup_by_name(child, wanted, descend_into_items, tolerant)
		if res:
			return res
	return null

func _looks_like_layouts_menu(pm: PopupMenu) -> bool:
	var sep_idx := -1
	for i in range(pm.item_count):
		if pm.is_item_separator(i):
			sep_idx = i
			break
	if sep_idx == -1:
		return false
	return sep_idx < pm.item_count - 1

# ---------- Cache and save ----------

func _refresh_layout_cache() -> void:
	_name_to_id.clear()
	if _layouts_menu != null:
		var sep_idx := -1
		for i in range(_layouts_menu.item_count):
			if _layouts_menu.is_item_separator(i):
				sep_idx = i
				break
		if sep_idx != -1:
			for j in range(sep_idx + 1, _layouts_menu.item_count):
				if _layouts_menu.is_item_separator(j):
					continue
				var label := _layouts_menu.get_item_text(j).strip_edges()
				if label.is_empty():
					continue
				var id := _layouts_menu.get_item_id(j)
				_name_to_id[label] = id
	_log("[AutoLayout] cached layouts: %s" % str(_name_to_id.keys()))
	_seed_settings_if_needed()
	_update_setting_hints()

func _seed_settings_if_needed() -> void:
	# Prefer "Default" if present, else the first non-empty discovered; never overwrite valid values.
	var preferred := ""
	if _name_to_id.has("Default"):
		preferred = "Default"
	else:
		for k in _name_to_id.keys():
			var s := str(k).strip_edges()
			if s != "":
				preferred = s
				break
	if preferred == "":
		_settings_notify()
		return
	for key in [KEY_2D, KEY_3D, KEY_GAME, KEY_ASSETLIB, KEY_SCRIPT, KEY_FALLBACK]:
		var val := _es_get_str(key, "")
		if val == "" or not _name_to_id.has(val):
			_settings.set_setting(key, preferred)
	_settings_notify()

func _update_setting_hints() -> void:
	# Strict enum when we have real names, suggestion list otherwise.
	var names := PackedStringArray()
	for k in _name_to_id.keys():
		var s := str(k).strip_edges()
		if s != "":
			names.push_back(s)
	names.sort()

	var hint_type := PROPERTY_HINT_ENUM_SUGGESTION
	var hint_string := "Default"
	if names.size() > 0:
		hint_type = PROPERTY_HINT_ENUM
		hint_string = _join_strings(names, ",")

	if hint_string == _hint_cached and hint_type == PROPERTY_HINT_ENUM:
		return
	_hint_cached = hint_string

	for key in [KEY_2D, KEY_3D, KEY_GAME, KEY_ASSETLIB, KEY_SCRIPT, KEY_FALLBACK]:
		_settings.add_property_info({
			"name": key,
			"type": TYPE_STRING,
			"hint": hint_type,
			"hint_string": hint_string
		})
	_settings_notify()

func _join_strings(arr: PackedStringArray, sep: String) -> String:
	var out := ""
	for i in range(arr.size()):
		if i > 0:
			out += sep
		out += arr[i]
	return out

func _throttled_save() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_save_ms >= SAVE_THROTTLE_MS:
		_last_save_ms = now
		queue_save_layout()

func _log(msg: String) -> void:
	if VERBOSE:
		print(msg)
