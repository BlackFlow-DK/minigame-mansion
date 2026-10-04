class_name BlobBallSim
extends RefCounted
## Blob Ball's ball physics: a pure, deterministic integrator (no engine physics), so the host
## and every client run the exact same code between host updates.
##
## The pitch is a rounded rectangle centred on the origin (goal lines at x = +-half_length,
## side walls at z = +-half_width, corners rounded by `corner_radius`) with a goal box behind
## each goal line (mouth |z| < goal_half_width, `goal_depth` deep, `goal_height` high). The
## walls are treated as infinitely high for the ball: it never leaves the pitch. Posts and
## crossbars are cylinders. Blobs are vertical capsules the ball bounces off (the ball yields:
## it is pushed out of the blob, never the other way round).
##
## Same inputs, same path: every call is plain float math in a fixed order.

## Ball radius (m). The ball is 1.4 m across.
const RADIUS := 0.7

## One ball state. Positions are the ball's centre.
class State:
	var pos: Vector3 = Vector3(0.0, 0.7, 0.0)
	var vel: Vector3 = Vector3.ZERO
	## Angular velocity (rad/s, world axes). Visual only, but simulated and synced.
	var spin: Vector3 = Vector3.ZERO

	func copy() -> State:
		var s := State.new()
		s.pos = pos
		s.vel = vel
		s.spin = spin
		return s

	func set_from(o: State) -> void:
		pos = o.pos
		vel = o.vel
		spin = o.spin


# --- Pitch geometry ----------------------------------------------------------------------------
var half_length: float = 11.0
var half_width: float = 6.5
var corner_radius: float = 2.5
var goal_half_width: float = 2.0
var goal_depth: float = 1.8
var goal_height: float = 2.2
var post_radius: float = 0.12

# --- Tuning --------------------------------------------------------------------------------------
## Light, floaty ball: lower than real gravity.
var gravity: float = 10.0
## Velocity lost per second in the air and on the ground (1/s, exponential).
var air_drag: float = 0.3
## Extra horizontal slow-down while rolling (m/s^2).
var roll_decel: float = 1.6
var floor_bounce: float = 0.62
var wall_bounce: float = 0.8
var post_bounce: float = 0.75
var net_bounce: float = 0.25
## Upward speeds below this after a floor bounce settle (m/s).
var rest_speed: float = 1.2
var max_speed: float = 20.0
## Shove: horizontal speed along the shover's facing and upward lift (m/s).
var kick_speed: float = 13.0
var kick_lift: float = 3.5
## Part of the ball's sideways velocity a kick keeps.
var kick_keep: float = 0.2


## Sets the pitch size; everything else follows.
func configure(length: float, width: float, goal_width: float) -> void:
	half_length = length * 0.5
	half_width = width * 0.5
	goal_half_width = goal_width * 0.5
	corner_radius = clampf(width * 0.2, 1.6, 2.6)


## Ball at the centre spot, at rest.
func kickoff_state() -> State:
	return State.new()


# --- Integrator ------------------------------------------------------------------------------------

## Advances `s` by `dt`: gravity, drag, motion, floor, walls, goal box, posts, rolling.
func step(s: State, dt: float) -> void:
	s.vel.y -= gravity * dt
	s.vel *= exp(-air_drag * dt)
	s.pos += s.vel * dt
	var on_floor := _collide_floor(s)
	collide_bounds(s)
	if on_floor:
		var h := Vector2(s.vel.x, s.vel.z)
		var sp := h.length()
		if sp > 0.0:
			var nsp := maxf(sp - roll_decel * dt, 0.0)
			h *= nsp / sp
			s.vel.x = h.x
			s.vel.z = h.y
		# Rolling without slipping: spin follows the ground speed quickly.
		var roll := Vector3(s.vel.z, 0.0, -s.vel.x) / RADIUS
		s.spin = s.spin.lerp(roll, minf(1.0, 12.0 * dt))
	else:
		s.spin *= exp(-0.4 * dt)
	var speed := s.vel.length()
	if speed > max_speed:
		s.vel *= max_speed / speed


## Keeps the ball out of the floor; true when it rests on or bounced off the floor.
func _collide_floor(s: State) -> bool:
	if s.pos.y > RADIUS + 0.001:
		return false
	s.pos.y = RADIUS
	if s.vel.y < 0.0:
		var up := -s.vel.y * floor_bounce
		s.vel.y = up if up > rest_speed else 0.0
	return s.vel.y < rest_speed + 0.001


## Walls, goal box, posts and crossbars. Public: contacts call it again after pushing the ball.
func collide_bounds(s: State) -> void:
	var r := RADIUS
	if absf(s.pos.x) > half_length and absf(s.pos.z) < goal_half_width:
		# Inside a goal box: back net, side nets, roof.
		var side := signf(s.pos.x)
		var lim_x := half_length + goal_depth - r
		if absf(s.pos.x) > lim_x:
			s.pos.x = side * lim_x
			_reflect(s, Vector3(side, 0.0, 0.0), net_bounce)
		var lim_z := goal_half_width - r
		if absf(s.pos.z) > lim_z:
			var sz := signf(s.pos.z)
			s.pos.z = sz * lim_z
			_reflect(s, Vector3(0.0, 0.0, sz), net_bounce)
		var roof := goal_height - r
		if s.pos.y > roof:
			s.pos.y = roof
			_reflect(s, Vector3.UP, net_bounce)
	else:
		var ax := half_length - r
		var az := half_width - r
		var cr := maxf(corner_radius - r, 0.05)
		# In front of a goal mouth (and under the bar) the end wall is open.
		var open_end := absf(s.pos.z) < goal_half_width and s.pos.y < goal_height
		var cx := absf(s.pos.x) - (ax - cr)
		var cz := absf(s.pos.z) - (az - cr)
		if cx > 0.0 and cz > 0.0 and not open_end:
			var len := sqrt(cx * cx + cz * cz)
			if len > cr:
				var n := Vector3(signf(s.pos.x) * cx / len, 0.0, signf(s.pos.z) * cz / len)
				s.pos -= n * (len - cr)
				_reflect(s, n, wall_bounce)
		else:
			if not open_end and absf(s.pos.x) > ax:
				var sx := signf(s.pos.x)
				s.pos.x = sx * ax
				_reflect(s, Vector3(sx, 0.0, 0.0), wall_bounce)
			if absf(s.pos.z) > az:
				var sz := signf(s.pos.z)
				s.pos.z = sz * az
				_reflect(s, Vector3(0.0, 0.0, sz), wall_bounce)
	_collide_posts(s)


func _collide_posts(s: State) -> void:
	var r := RADIUS
	var reach := r + post_radius
	for sx: float in [-1.0, 1.0]:
		var gx := sx * half_length
		if absf(s.pos.x - gx) > reach:
			continue
		# Posts: vertical cylinders from the ground to the bar.
		if s.pos.y - r < goal_height:
			for sz: float in [-1.0, 1.0]:
				var d := Vector2(s.pos.x - gx, s.pos.z - sz * goal_half_width)
				var len := d.length()
				if len < reach and len > 0.0001:
					var n := Vector3(d.x / len, 0.0, d.y / len)
					s.pos += n * (reach - len)
					_reflect(s, -n, post_bounce)
		# Crossbar: a horizontal cylinder across the mouth.
		if absf(s.pos.z) < goal_half_width:
			var d := Vector2(s.pos.x - gx, s.pos.y - goal_height)
			var len := d.length()
			if len < reach and len > 0.0001:
				var n := Vector3(d.x / len, d.y / len, 0.0)
				s.pos += n * (reach - len)
				_reflect(s, -n, post_bounce)


## Bounces the velocity off a surface; `n` points OUT of the allowed region (into the wall),
## so a velocity along +n is moving into it.
func _reflect(s: State, n: Vector3, bounce: float) -> void:
	var vn := s.vel.dot(n)
	if vn > 0.0:
		s.vel -= n * vn * (1.0 + bounce)
		var tangential := s.vel - n * s.vel.dot(n)
		s.vel -= tangential * 0.06


# --- Blobs ---------------------------------------------------------------------------------------

## Ball vs. one blob capsule (centre axis from `p_pos.y + seg_lo` to `p_pos.y + seg_hi`,
## radius `p_radius`) moving at `p_vel`. The ball is pushed out; if they close in, the ball
## takes the blob's speed along the contact normal plus `bounce` of the closing speed.
## `tolerance` > 0 treats near misses as contact (a client's reported touch on the host).
## Returns Vector2(closing speed, ball's own speed into the blob before the hit); x < 0 = no
## contact, x = 0 = touching but not closing.
func contact(s: State, p_pos: Vector3, p_vel: Vector3, p_radius: float, seg_lo: float, seg_hi: float,
		bounce: float, tolerance: float = 0.0) -> Vector2:
	var cy := clampf(s.pos.y, p_pos.y + seg_lo, p_pos.y + seg_hi)
	var c := Vector3(p_pos.x, cy, p_pos.z)
	var d := s.pos - c
	var dist := d.length()
	var min_d := RADIUS + p_radius
	if dist >= min_d + tolerance:
		return Vector2(-1.0, 0.0)
	var n := d / dist if dist > 0.0001 else Vector3.RIGHT
	if dist < min_d:
		s.pos += n * (min_d - dist)
		if s.pos.y < RADIUS:
			s.pos.y = RADIUS
	var incoming := -s.vel.dot(n)
	var vrel := (s.vel - p_vel).dot(n)
	if vrel >= 0.0:
		return Vector2(0.0, incoming)
	s.vel -= n * vrel * (1.0 + bounce)
	return Vector2(-vrel, incoming)


## True when a blob at `p_pos` looking along `facing` can shove the ball: the ball's surface
## within `reach` of the blob's (0.4 m radius) surface, in front (within `cone_deg` of facing)
## and low enough to hit (its bottom below the blob's head + `head_room`).
func in_kick_reach(s: State, p_pos: Vector3, facing: Vector3, reach: float, cone_deg: float = 70.0,
		head_room: float = 0.5) -> bool:
	var to := Vector2(s.pos.x - p_pos.x, s.pos.z - p_pos.z)
	var dist := to.length()
	if dist > RADIUS + 0.4 + reach:
		return false
	if s.pos.y - RADIUS > p_pos.y + 1.0 + head_room or s.pos.y + RADIUS < p_pos.y:
		return false
	var f := Vector2(facing.x, facing.z)
	if f.length_squared() < 0.0001 or dist < 0.0001:
		return true
	return f.normalized().dot(to / dist) >= cos(deg_to_rad(cone_deg))


## A shove on the ball along `facing` (flattened), scaled by `power`.
func kick(s: State, facing: Vector3, power: float = 1.0) -> void:
	var f := Vector3(facing.x, 0.0, facing.z)
	f = f.normalized() if f.length_squared() > 0.0001 else Vector3.RIGHT
	var flat := Vector3(s.vel.x, 0.0, s.vel.z)
	var along := flat.dot(f)
	var sideways := flat - f * along
	var speed := maxf(kick_speed * power, along)
	s.vel = f * speed + sideways * kick_keep + Vector3.UP * kick_lift * power
	s.spin = Vector3(f.z, 0.0, -f.x) * (speed / RADIUS) * 1.2


# --- Rules helpers ------------------------------------------------------------------------------

## 0 when the ball's centre is past the left goal line (x < 0) inside the mouth, 1 past the
## right one, -1 otherwise.
func goal_side(s: State) -> int:
	if absf(s.pos.z) >= goal_half_width:
		return -1
	if s.pos.x < -half_length:
		return 0
	if s.pos.x > half_length:
		return 1
	return -1


## True for a point on the pitch (or inside a goal box), at least `margin` from the walls.
func inside(pos: Vector3, margin: float = 0.0) -> bool:
	if absf(pos.x) > half_length and absf(pos.z) < goal_half_width - margin:
		return absf(pos.x) < half_length + goal_depth - margin
	var ax := half_length - margin
	var az := half_width - margin
	if absf(pos.x) > ax or absf(pos.z) > az:
		return false
	var cr := maxf(corner_radius - margin, 0.01)
	var cx := absf(pos.x) - (ax - cr)
	var cz := absf(pos.z) - (az - cr)
	if cx > 0.0 and cz > 0.0:
		return cx * cx + cz * cz <= cr * cr
	return true


## `pos` pulled onto the pitch, `margin` inside the walls (goal boxes excluded), y = 0.
func clamp_inside(pos: Vector3, margin: float = 0.6) -> Vector3:
	var ax := half_length - margin
	var az := half_width - margin
	var p := Vector3(clampf(pos.x, -ax, ax), 0.0, clampf(pos.z, -az, az))
	var cr := maxf(corner_radius - margin, 0.01)
	var cx := absf(p.x) - (ax - cr)
	var cz := absf(p.z) - (az - cr)
	if cx > 0.0 and cz > 0.0:
		var len := sqrt(cx * cx + cz * cz)
		if len > cr:
			p.x -= signf(p.x) * cx * (1.0 - cr / len)
			p.z -= signf(p.z) * cz * (1.0 - cr / len)
	return p
