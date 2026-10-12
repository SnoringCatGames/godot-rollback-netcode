extends Node
## Stands in for hopnbop's G autoload (src/core/global.gd), which
## core/frame_driver.gd reads (G.is_lobby_active). Only the name has to
## resolve: GDScript doesn't check member access on it at compile time.
## Delete this stub, and its autoload in project.godot, once the addon
## stops reading G.
