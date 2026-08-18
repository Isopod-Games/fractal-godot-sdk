extends GdUnitTestSuite
## Reproduces issue #355: a single playthrough fragmented across two ClickHouse
## session_ids. The collector derives session_id deterministically by hashing
## the SDK's session_token (FNV-1a, collector/internal/ingest/handler.go:196),
## so two separate app launches that mint the identical session_token collapse
## into the same session_id even though they are genuinely different sessions.
##
## analytics.gd::_generate_session_token() draws its only entropy from a
## freshly-seeded RandomNumberGenerator. If two independent launches happen to
## seed that RNG identically (randomize()'s seed is time-derived, not
## guaranteed distinct across launches), the deterministic PRNG output, and
## therefore the token, collides too. See docs/issue-355-test-plan.md.

const FractalAnalyticsClass = preload("res://addons/fractal/analytics/analytics.gd")

var analytics: Node


func before_test() -> void:
	analytics = FractalAnalyticsClass.new()
	add_child(analytics)
	await get_tree().process_frame


func after_test() -> void:
	if analytics:
		analytics.queue_free()


## Simulates two separate process launches whose randomize()-seeded RNG
## collided (the mechanism behind the reported bug) by handing each call an
## RNG with the same explicit seed. Session tokens, and therefore the
## ClickHouse session_id derived from them, must still come out distinct.
func test_colliding_rng_seed_still_produces_distinct_tokens() -> void:
	var rng1 := RandomNumberGenerator.new()
	rng1.seed = 42

	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 42

	var token1: String = analytics._generate_session_token(rng1)
	await get_tree().create_timer(0.01).timeout
	var token2: String = analytics._generate_session_token(rng2)

	assert_str(token1).is_not_equal(token2)
