# Auto Layout Switcher
The Auto Layout Switcher is a Godot plugin that automatically switches Editor Layours depending on the current screen (2D, 3D, Script, Game, AssetLib).
For example, you can change the layout when in Script view so that the code editor has more space.

![Image](https://github.com/Processuales/Auto-Layout-Switcher/blob/main/icon.png)

## Install
1. Download the files.
2. Place the addon folder into your the root of your project.
3. In **Project > Project Settings > Plugins**, enable **Auto Layout Switcher**.
4. In **Editor > Editor Settings > Auto Layout Switcher**, you can change the layout for every view.

## Issues
There is a *very* minor delay when switching workspaces, because Godot does not have an in-built way to switch layouts through code. The plugin gets around this limitation finding the “Editor Layouts” menu node in the editor UI tree and emitting the same signal that Godot emits when you select a layout manually.

## Godot Versions
Only tested with Godot 4.5, but should work 4.4
