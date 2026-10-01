extends GameTest
## Balance guard: a small version of tools/balance-batch.ps1. Each test plays one block of
## BLOCK whole bot-only rounds of one minigame with 4 bots through the real Session flow
## (tools/balance/balance_runner.gd: slot 0 is a bot too, personalities rotate over the seats
## once per block) and asserts every round ends within its time limit. The wins are pooled
## over every block of the file (3 x 3 + 2 = 11 blocks, 44 rounds); once the pool is full, no
## slot may have won more than 35 %.
## Blocks, not one test per minigame: a 4-round block takes ~10-18 s on a quiet machine (Coin
## Scramble's fixed 45 s rounds are the slowest), well inside the runner's 60 s per test even
## when the machine is busy; 8 Coin Scramble rounds in one test took ~36 s. Each block uses
## its own seed (SEEDS), so the blocks play different rounds and the pool is the same size
## (44 rounds) as when each minigame was one test: the slot-bias check is as strong as before.
## Run the whole file (`-Filter test_balance`) for the pooled check; one test alone checks
## only its own rounds' time limits.
## Statistics: even with no bias at all, some seat tops 35 % of 44 rounds for roughly one seed
## in five (a fair seat's share has a standard deviation of ~6 points here), so this is a
## coarse guard against a gross bias with fixed seeds; the real numbers come from the batch
## tool (docs/balance.md: 2/4/8 players, more rounds).

const Runner := preload("res://tools/balance/balance_runner.gd")
const PLAYERS := 4
## Rounds per test: one personality block (a multiple of PLAYERS keeps the rotation even).
const BLOCK := 4
## Block seeds. Seed 1 is the docs/balance.md batches' seed; 2 and 3 add rounds.
const SEEDS: Array[int] = [1, 2, 3]
## Coin Scramble always runs its full 45 s: two blocks instead of three.
const COIN_SEEDS: Array[int] = [1, 2]
const POOL_TARGET := 44
const MAX_SLOT_SHARE := 0.35
## Session's backstop ends a round 1 s after its limit; allow a frame or two on top.
const LIMIT_SLACK := 1.2

static var _pool_wins: Array[float] = []
static var _pool_rounds: int = 0
static var _pool_keys: Array[String] = []


func _batch(id: StringName, seed_value: int) -> void:
	var runner := Runner.new()
	add_child(runner)
	var stats: Dictionary = await runner.run_batch(id, PLAYERS, BLOCK, seed_value)
	runner.queue_free()
	print(Runner.report(stats))
	assert_eq(stats["rounds"], BLOCK, "%s: every round played" % id)
	assert_eq(stats["never"], 0, "%s: no round runs on past its limit" % id)
	var limit: float = stats["time_limit"]
	var lengths: Array = stats["lengths"]
	if limit > 0.0 and not lengths.is_empty():
		assert_true(float(lengths.max()) <= limit + LIMIT_SLACK,
			"%s: rounds end within the %.0f s limit (longest %.1f s)" % [id, limit, lengths.max()])
	_pool("%s/%d" % [id, seed_value], stats)


func _pool(key: String, stats: Dictionary) -> void:
	if _pool_keys.has(key):
		return
	_pool_keys.append(key)
	if _pool_wins.is_empty():
		_pool_wins.resize(PLAYERS)
		_pool_wins.fill(0.0)
	for s in PLAYERS:
		_pool_wins[s] += float(stats["wins"][s])
	_pool_rounds += int(stats["rounds"])
	if _pool_rounds < POOL_TARGET:
		return
	var parts: PackedStringArray = []
	var worst := 0.0
	for s in PLAYERS:
		var share := _pool_wins[s] / _pool_rounds
		worst = maxf(worst, share)
		parts.append("%d:%.0f%%" % [s, 100.0 * share])
	print("  pooled over %d rounds of %s: wins by slot %s" % [_pool_rounds, _pool_keys, "  ".join(parts)])
	assert_true(worst <= MAX_SLOT_SHARE, "no slot wins more than %.0f%% of %d pooled rounds (%s)" % [
		100.0 * MAX_SLOT_SHARE, _pool_rounds, "  ".join(parts)])


func test_floor_is_lava_block_1() -> void:
	await _batch(&"floor_is_lava", SEEDS[0])


func test_floor_is_lava_block_2() -> void:
	await _batch(&"floor_is_lava", SEEDS[1])


func test_floor_is_lava_block_3() -> void:
	await _batch(&"floor_is_lava", SEEDS[2])


func test_bumper_sumo_block_1() -> void:
	await _batch(&"bumper_sumo", SEEDS[0])


func test_bumper_sumo_block_2() -> void:
	await _batch(&"bumper_sumo", SEEDS[1])


func test_bumper_sumo_block_3() -> void:
	await _batch(&"bumper_sumo", SEEDS[2])


func test_hot_potato_block_1() -> void:
	await _batch(&"hot_potato", SEEDS[0])


func test_hot_potato_block_2() -> void:
	await _batch(&"hot_potato", SEEDS[1])


func test_hot_potato_block_3() -> void:
	await _batch(&"hot_potato", SEEDS[2])


func test_coin_scramble_block_1() -> void:
	await _batch(&"coin_scramble", COIN_SEEDS[0])


func test_coin_scramble_block_2() -> void:
	await _batch(&"coin_scramble", COIN_SEEDS[1])
