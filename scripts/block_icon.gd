class_name BlockIcon
extends Control

var block_name := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func set_block(value: String) -> void:
	block_name = value
	queue_redraw()


func _process(_delta: float) -> void:
	if block_name in ["water", "lava"] and Engine.get_process_frames() % 8 == 0:
		queue_redraw()


func _draw() -> void:
	if block_name.is_empty() or not BlockDefs.BLOCKS.has(block_name):
		return
	var icon_size := minf(size.x, size.y)
	var origin := (size - Vector2(icon_size, icon_size)) * 0.5
	BlockDefs.draw_hotbar_icon(self, origin, icon_size, block_name, Engine.get_process_frames())
