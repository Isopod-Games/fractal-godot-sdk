extends GdUnitTestSuite

const FractalBreadcrumbsClass = preload("res://addons/fractal/errors/breadcrumbs.gd")


func test_add_and_retrieve() -> void:
	var b: FractalBreadcrumbs = FractalBreadcrumbsClass.new(20)
	b.add("clicked start", "ui", "info")
	var crumbs: Array = b.all()
	assert_int(crumbs.size()).is_equal(1)
	assert_str(crumbs[0].message).is_equal("clicked start")
	assert_str(crumbs[0].category).is_equal("ui")
	assert_str(crumbs[0].level).is_equal("info")


func test_ring_buffer_drops_oldest() -> void:
	var b: FractalBreadcrumbs = FractalBreadcrumbsClass.new(3)
	b.add("a")
	b.add("b")
	b.add("c")
	b.add("d")
	var crumbs: Array = b.all()
	assert_int(crumbs.size()).is_equal(3)
	assert_str(crumbs[0].message).is_equal("b")
	assert_str(crumbs[2].message).is_equal("d")


func test_extra_data_attached() -> void:
	var b: FractalBreadcrumbs = FractalBreadcrumbsClass.new()
	b.add("network call", "http", "info", {"url": "/foo", "ms": 42})
	var crumbs: Array = b.all()
	assert_dict(crumbs[0].data).is_equal({"url": "/foo", "ms": 42})


func test_clear() -> void:
	var b: FractalBreadcrumbs = FractalBreadcrumbsClass.new()
	b.add("x")
	b.add("y")
	b.clear()
	assert_int(b.size()).is_equal(0)


func test_min_max_clamp() -> void:
	# Constructed with 0 or negative max should be clamped to >= 1.
	var b: FractalBreadcrumbs = FractalBreadcrumbsClass.new(0)
	b.add("a")
	b.add("b")
	# At least one breadcrumb should fit.
	assert_int(b.size()).is_greater_equal(1)
