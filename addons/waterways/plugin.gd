# Copyright © 2020 Kasper Arnklit Frandsen - MIT License
# See `LICENSE.md` included in the source distribution for details.
tool
extends EditorPlugin

const WaterHelperMethods = preload("./water_helper_methods.gd")
const RiverManager = preload("./river_manager.gd")
const RiverGizmo = preload("./river_gizmo.gd")
const ProgressWindow = preload("./progress_window.tscn")

var river_gizmo = RiverGizmo.new()

var _river_controls = preload("./gui/river_controls.tscn").instance()
var _edited_node = null
var _progress_window = null
var _editor_selection : EditorSelection = null
var _mode := "select"
var snap_to_colliders := false


func _enter_tree() -> void:
	add_custom_type("River", "Spatial", preload("./river_manager.gd"), preload("icon.svg"))
	add_spatial_gizmo_plugin(river_gizmo)
	river_gizmo.editor_plugin = self
	_river_controls.connect("mode", self, "_on_mode_change")
	_river_controls.connect("options", self, "_on_option_change")
	_progress_window = ProgressWindow.instance()
	_river_controls.add_child(_progress_window)
	_editor_selection = get_editor_interface().get_selection()
	_editor_selection.connect("selection_changed", self, "_on_selection_change")
	connect("scene_changed", self, "_on_scene_changed");
	connect("scene_closed", self, "_on_scene_closed");


func _on_generate_flowmap_pressed() -> void:
	# set a working icon next to the river menu
	_edited_node.bake_texture()


func _on_generate_mesh_pressed() -> void:
	# set a working icon next to the river menu
	_edited_node.spawn_mesh()


func _on_debug_view_changed(index : int) -> void:
	_edited_node.set_debug_view(index)


func _exit_tree() -> void:
	remove_custom_type("River")
	remove_spatial_gizmo_plugin(river_gizmo)
	_river_controls.disconnect("mode", self, "_on_mode_change")
	_river_controls.disconnect("options", self, "on_option_change")
	_editor_selection.disconnect("selection_changed", self, "_on_selection_change")
	disconnect("scene_changed", self, "_on_scene_changed");
	disconnect("scene_closed", self, "_on_scene_closed");
	_hide_control_panel()


func handles(node):
	return node is RiverManager


func edit(node):
	_show_control_panel()
	_edited_node = node as RiverManager


func _on_selection_change() -> void:
	_editor_selection = get_editor_interface().get_selection()
	var selected = _editor_selection.get_selected_nodes()
	if len(selected) == 0:
		return
	if selected[0] is RiverManager:
		_river_controls.menu.debug_view_menu_selected = _edited_node.debug_view
		if not _edited_node.is_connected("progress_notified", self, "_river_progress_notified"):
			_edited_node.connect("progress_notified", self, "_river_progress_notified")
	else:
		_edited_node = null
		if _river_controls.get_parent():
			_hide_control_panel()


func _on_scene_changed(scene_root : Node) -> void:
	if _edited_node != null:
		if _edited_node.owner == scene_root:
			_show_control_panel()
	else:
		if _river_controls.get_parent():
			_hide_control_panel()


func _on_scene_closed(_value) -> void:
	if _river_controls.get_parent():
		_hide_control_panel()


func _on_mode_change(mode) -> void:
	_mode = mode


func _on_option_change(option, value) -> void:
	snap_to_colliders = value
	if snap_to_colliders:
		WaterHelperMethods.reset_all_colliders(_edited_node.get_tree().root)


func forward_spatial_gui_input(camera: Camera, event: InputEvent) -> bool:
	if not _edited_node:
		return false
	
	var global_transform: Transform = _edited_node.transform
	if _edited_node.is_inside_tree():
		global_transform = _edited_node.get_global_transform()
	var global_inverse: Transform = global_transform.affine_inverse()
	
	if (event is InputEventMouseButton) and (event.button_index == BUTTON_LEFT):
		
		var ray_from = camera.project_ray_origin(event.position)
		var ray_dir = camera.project_ray_normal(event.position)
		var g1 = global_inverse.xform(ray_from)
		var g2 = global_inverse.xform(ray_from + ray_dir * 4096)
		
		# Iterate through points to find closest segment
		var curve_points = _edited_node.get_curve_points()
		var closest_distance = 4096.0
		var closest_segment = -1
		
		for point in curve_points.size() -1:
			var p1 = curve_points[point]
			var p2 = curve_points[point + 1]
			var result  = Geometry.get_closest_points_between_segments(p1, p2, g1, g2)
			var dist = result[0].distance_to(result[1])
			if dist < closest_distance:
				closest_distance = dist
				closest_segment = point
		
		# Iterate through baked points to find the closest position on the
		# curved path
		var baked_curve_points = _edited_node.curve.get_baked_points()
		var baked_closest_distance = 4096.0
		var baked_closest_point = Vector3()
		var baked_point_found = false
		
		for baked_point in baked_curve_points.size() - 1:
			var p1 = baked_curve_points[baked_point]
			var p2 = baked_curve_points[baked_point + 1]
			var result  = Geometry.get_closest_points_between_segments(p1, p2, g1, g2)
			var dist = result[0].distance_to(result[1])
			if dist < 0.1 and dist < baked_closest_distance:
				baked_closest_distance = dist
				baked_closest_point = result[0]
				baked_point_found = true
		
		# In case we were close enough to a line segment to find a segment,
		# but not close enough to the curved line
		if not baked_point_found:
			closest_segment = -1
		
		# We'll use this closest point to add a point in between if on the line
		# and to remove if close to a point
		if _mode == "select":
			return false
		if _mode == "add" and not event.pressed:
			# if we don't have a point on the line, we'll calculate a point
			# based of a plane of the last point of the curve
			if closest_segment == -1:
				var end_pos = _edited_node.curve.get_point_position(_edited_node.curve.get_point_count() - 1)
				var end_pos_global = _edited_node.to_global(end_pos)
				var plane := Plane(end_pos_global, end_pos_global + camera.transform.basis.x, end_pos_global + camera.transform.basis.y)
				var new_pos
				if snap_to_colliders:
					var space_state = _edited_node.get_world().direct_space_state
					var result = space_state.intersect_ray(ray_from, ray_from + ray_dir * 4096)
					if result:
						new_pos = result.position
					else:
						return false
				else:
					new_pos = plane.intersects_ray(ray_from, ray_from + ray_dir * 4096)
				baked_closest_point = _edited_node.to_local(new_pos)
			
			var ur := get_undo_redo()
			ur.create_action("Add River point")
			ur.add_do_method(_edited_node, "add_point", baked_closest_point, closest_segment)
			ur.add_do_method(_edited_node, "properties_changed")
			ur.add_do_method(_edited_node, "set_materials", "valid_flowmap", false)
			ur.add_do_property(_edited_node, "valid_flowmap", false)
			ur.add_do_method(_edited_node, "update_configuration_warning")
			if closest_segment == -1:
				ur.add_undo_method(_edited_node, "remove_point", _edited_node.curve.get_point_count()) # remove last
			else:
				ur.add_undo_method(_edited_node, "remove_point", closest_segment + 1)
			ur.add_undo_method(_edited_node, "properties_changed")
			ur.add_undo_method(_edited_node, "set_materials", "valid_flowmap", _edited_node.valid_flowmap)
			ur.add_undo_property(_edited_node, "valid_flowmap", _edited_node.valid_flowmap)
			ur.add_undo_method(_edited_node, "update_configuration_warning")
			ur.commit_action()
		if _mode == "remove" and not event.pressed:
			# A closest_segment of -1 means we didn't press close enough to a
			# point for it to be removed
			if not closest_segment == -1: 
				var closest_index = _edited_node.get_closest_point_to(baked_closest_point)
				#_edited_node.remove_point(closest_index)
				var ur = get_undo_redo()
				ur.create_action("Remove River point")
				ur.add_do_method(_edited_node, "remove_point", closest_index)
				ur.add_do_method(_edited_node, "properties_changed")
				ur.add_do_method(_edited_node, "set_materials", "valid_flowmap", false)
				ur.add_do_property(_edited_node, "valid_flowmap", false)
				ur.add_do_method(_edited_node, "update_configuration_warning")
				if closest_index == _edited_node.curve.get_point_count() - 1:
					ur.add_undo_method(_edited_node, "add_point", _edited_node.curve.get_point_position(closest_index), -1)
				else:
					ur.add_undo_method(_edited_node, "add_point", _edited_node.curve.get_point_position(closest_index), closest_index - 1, _edited_node.curve.get_point_out(closest_index), _edited_node.widths[closest_index])
				ur.add_undo_method(_edited_node, "properties_changed")
				ur.add_undo_method(_edited_node, "set_materials", "valid_flowmap", _edited_node.valid_flowmap)
				ur.add_undo_property(_edited_node, "valid_flowmap", _edited_node.valid_flowmap)
				ur.add_undo_method(_edited_node, "update_configuration_warning")
				ur.commit_action()
		return true
	return false


func _river_progress_notified(progress : float, message : String) -> void:
	if message == "finished":
		_progress_window.hide()
	
	else:
		if not _progress_window.visible:
			_progress_window.popup_centered()
		
		_progress_window.show_progress(message, progress)


func _show_control_panel() -> void:
	if not _river_controls.get_parent():
		add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _river_controls)
		_river_controls.menu.connect("generate_flowmap", self, "_on_generate_flowmap_pressed")
		_river_controls.menu.connect("generate_mesh", self, "_on_generate_mesh_pressed")
		_river_controls.menu.connect("debug_view_changed", self, "_on_debug_view_changed")


func _hide_control_panel() -> void:
	if _river_controls.get_parent():
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _river_controls)
		_river_controls.menu.disconnect("generate_flowmap", self, "_on_generate_flowmap_pressed")
		_river_controls.menu.disconnect("generate_mesh", self, "_on_generate_mesh_pressed")
		_river_controls.menu.disconnect("debug_view_changed", self, "_on_debug_view_changed")