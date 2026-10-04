class_name RenderCensus
extends RefCounted
## Counts what a subtree asks the renderer for, without a GPU (headless tests use it to catch
## draw-call regressions; tools/perf-run.ps1 -Census prints it per child of the scene).
## Owner: look and effects. Static only.
##
##   var c := RenderCensus.count(minigame)
##   c["lights"]          visible OmniLight3D + SpotLight3D (real per-pixel lights)
##   c["shadow_lights"]   of those, the ones casting shadows
##   c["surfaces"]        visible MeshInstance3D surfaces (one draw each per pass)
##   c["shadow_surfaces"] of those, the shadow casters (drawn again per shadow split)
##   c["outlined"]        of those, the ones whose material has a next_pass (outline: +1 draw)
##   c["multimesh"]       visible MultiMeshInstance3D nodes (one draw per surface, any count)
##   c["materials"]       distinct materials on visible surfaces
##   c["labels"]          visible Label3D;  c["particles"]  visible CPU/GPU particle emitters
##   c["est_draws"]       rough draws per frame: surfaces * 2 (depth + colour)
##                        + shadow casters + outlined + multimesh surfaces * 2 + labels

static func count(root: Node) -> Dictionary:
	var c := {"lights": 0, "shadow_lights": 0, "surfaces": 0, "shadow_surfaces": 0, "outlined": 0,
		"multimesh": 0, "materials": 0, "labels": 0, "particles": 0, "est_draws": 0}
	if root == null:
		return c
	var mats: Dictionary = {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and not (n as Node3D).visible:
			continue
		if n is SubViewport:
			continue  # its own world: count it separately
		if n is OmniLight3D or n is SpotLight3D:
			c["lights"] += 1
			if (n as Light3D).shadow_enabled:
				c["shadow_lights"] += 1
		elif n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh:
				var shadow := mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				for s in mi.mesh.get_surface_count():
					var m := mi.get_active_material(s)
					c["surfaces"] += 1
					if shadow:
						c["shadow_surfaces"] += 1
					if m and m.next_pass:
						c["outlined"] += 1
					mats[m] = true
		elif n is MultiMeshInstance3D:
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm and mm.mesh and mm.visible_instance_count != 0 and mm.instance_count > 0:
				c["multimesh"] += mm.mesh.get_surface_count()
		elif n is Label3D:
			c["labels"] += 1
		elif n is CPUParticles3D or n is GPUParticles3D:
			c["particles"] += 1
		for ch in n.get_children():
			stack.append(ch)
	c["materials"] = mats.size()
	c["est_draws"] = int(c["surfaces"]) * 2 + int(c["shadow_surfaces"]) + int(c["outlined"]) \
		+ int(c["multimesh"]) * 2 + int(c["labels"])
	return c


## One line per child of `root` (and `root`'s own total), biggest estimate first.
static func report(root: Node) -> String:
	var rows: Array = []
	for ch in root.get_children():
		var c := count(ch)
		if int(c["est_draws"]) > 0 or int(c["lights"]) > 0:
			rows.append([ch.name, c])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return int(a[1]["est_draws"]) > int(b[1]["est_draws"]))
	var lines: PackedStringArray = []
	var total := count(root)
	lines.append("%-28s %s" % [str(root.name) + " (total)", _fmt(total)])
	for r: Array in rows:
		lines.append("  %-26s %s" % [str(r[0]).left(26), _fmt(r[1])])
	return "\n".join(lines)


static func _fmt(c: Dictionary) -> String:
	return "draws~%d surf %d shadow %d outl %d mm %d mats %d lights %d(%d sh) labels %d fx %d" % [
		c["est_draws"], c["surfaces"], c["shadow_surfaces"], c["outlined"], c["multimesh"], c["materials"],
		c["lights"], c["shadow_lights"], c["labels"], c["particles"]]
