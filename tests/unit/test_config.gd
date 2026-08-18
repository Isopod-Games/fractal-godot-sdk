extends GdUnitTestSuite

const FractalConfigClass = preload("res://addons/fractal/core/config.gd")


func test_defaults() -> void:
	var c: FractalConfig = FractalConfigClass.new()
	assert_bool(c.analytics_enabled).is_true()
	assert_bool(c.errors_enabled).is_true()
	assert_bool(c.translations_enabled).is_false()
	assert_int(c.analytics_batch_size).is_equal(10)
	assert_str(c.environment).is_equal("development")


func test_merged_overrides_existing_fields() -> void:
	var base: FractalConfig = FractalConfigClass.new()
	base.api_key = "base"
	base.analytics_enabled = true
	var merged: FractalConfig = base.merged({
		"api_key": "override",
		"analytics_enabled": false,
		"environment": "production",
	})
	assert_str(merged.api_key).is_equal("override")
	assert_bool(merged.analytics_enabled).is_false()
	assert_str(merged.environment).is_equal("production")
	# Original is unchanged.
	assert_str(base.api_key).is_equal("base")
	assert_bool(base.analytics_enabled).is_true()


func test_merged_ignores_unknown_keys() -> void:
	var base: FractalConfig = FractalConfigClass.new()
	var merged: FractalConfig = base.merged({"not_a_real_field": 99})
	# Should not raise, and the resulting config is still a valid FractalConfig.
	assert_object(merged).is_not_null()


func test_is_valid_requires_api_key() -> void:
	var c: FractalConfig = FractalConfigClass.new()
	c.api_key = ""
	var v: Dictionary = c.is_valid()
	assert_bool(v.valid).is_false()
	assert_array(v.errors).contains(["api_key is required"])


func test_is_valid_when_translations_enabled_does_not_require_project_id() -> void:
	var c: FractalConfig = FractalConfigClass.new()
	c.api_key = "k"
	c.collector_url = "http://localhost"
	c.api_url = "http://localhost"
	c.translations_enabled = true
	c.project_id = ""
	assert_bool(c.is_valid().valid).is_true()


func test_is_valid_with_only_translations() -> void:
	var c: FractalConfig = FractalConfigClass.new()
	c.api_key = "k"
	c.analytics_enabled = false
	c.errors_enabled = false
	c.translations_enabled = true
	c.collector_url = ""  # not needed when both POST subsystems are off
	c.api_url = "http://localhost"
	assert_bool(c.is_valid().valid).is_true()
