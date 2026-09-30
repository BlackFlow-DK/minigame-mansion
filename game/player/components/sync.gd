class_name SyncComponent
extends PlayerComponent
## Replicates player state and events to other peers. Owner: player sync.
## Remote copies do not tick; this component moves them.
## Stub: offline only, relays nothing.


## Called by Player.emit_event after the local emit. Deliver to every other peer, which
## calls `player.receive_event(event, args)` (that does not relay again).
func relay_event(_event: StringName, _args: Array) -> void:
	pass


## Called by Player.apply_impulse on a peer that is not the authority. Deliver to the
## authority, which calls `player.apply_impulse(impulse, source)`.
func relay_impulse(_impulse: Vector3, _source: Player) -> void:
	pass
