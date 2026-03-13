package fluids

import "../graphics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem/virtual"

@(private)
DELTA_COEFFICIENT: f32 : 8
@(private)
LOCAL_COMPUTE_SIZE: int : 16
@(private)
JACOBI_ITERATIONS: int : 40
@(private)
MAX_INJECTION: int : 60

@(private)
divergence_shader :: cstring(#load("fluids_divergence.glsl"))
@(private)
compute_shader :: cstring(#load("fluids_compute.glsl"))
@(private)
compute_simple_shader :: cstring(#load("fluids_compute_simple.glsl"))
@(private)
visualize_simple_shader :: cstring(#load("fluids_visualize_simple.glsl"))
@(private)
visualize_shader :: cstring(#load("fluids_visualize.glsl"))
@(private)
jacobi_shader :: cstring(#load("fluids_jacobi.glsl"))
@(private)
gradient_shader :: cstring(#load("fluids_gradient.glsl"))
@(private)
boundary_shader :: cstring(#load("fluids_boundary.glsl"))

SimulationType :: enum {
	SIMPLE,
	ACCURATE,
}

Injection :: struct {
	x, y:     i32,
	velocity: [2]f32,
	density:  f32,
	_pad:     f32,
}

FluidSim :: struct {
	arena:                                                                virtual.Arena,
	alloc:                                                                runtime.Allocator,
	simulation_type:                                                      SimulationType,
	width, height, size:                                                  int,
	buffer_size:                                                          uint,
	k, v, w:                                                              f32,
	ssbo_a, ssbo_b, ssbo_divergence:                                      uint,
	ssbo_injections, ssbo_pressure_a, ssbo_pressure_b:                    uint,
	data_a, data_b, data_read:                                            [dynamic][4]f32,
	data_divergence, data_pressure_a, data_pressure_b:                    [dynamic]f32,
	compute_shader_loaded, divergence_shader_loaded:                      graphics.Shader,
	jacobi_shader_loaded, gradient_shader_loaded, boundary_shader_loaded: graphics.Shader,
	visualize_simple_shader_loaded, visualize_shader_loaded:              graphics.Shader,
	injections:                                                           [dynamic]Injection,
	draw_texture:                                                         graphics.Texture,
	destroyed:                                                            bool,
}

destroy :: proc(fluid_sim: ^FluidSim) {
	if fluid_sim.destroyed do return
	if fluid_sim.simulation_type == .ACCURATE {
		virtual.arena_destroy(&fluid_sim.arena)
		graphics.unload_ssbo(&fluid_sim.ssbo_a)
		graphics.unload_ssbo(&fluid_sim.ssbo_b)
		graphics.unload_ssbo(&fluid_sim.ssbo_injections)
		graphics.unload_ssbo(&fluid_sim.ssbo_divergence)
		graphics.unload_ssbo(&fluid_sim.ssbo_pressure_a)
		graphics.unload_ssbo(&fluid_sim.ssbo_pressure_b)

		graphics.unload_compute_shader(&fluid_sim.compute_shader_loaded)
		graphics.unload_compute_shader(&fluid_sim.jacobi_shader_loaded)
		graphics.unload_compute_shader(&fluid_sim.gradient_shader_loaded)
		graphics.unload_compute_shader(&fluid_sim.divergence_shader_loaded)
		graphics.unload_compute_shader(&fluid_sim.gradient_shader_loaded)
		graphics.unload_shader(&fluid_sim.visualize_shader_loaded)
		graphics.unload_texture(&fluid_sim.draw_texture)
	} else {
		virtual.arena_destroy(&fluid_sim.arena)
		graphics.unload_ssbo(&fluid_sim.ssbo_a)
		graphics.unload_ssbo(&fluid_sim.ssbo_b)
		graphics.unload_ssbo(&fluid_sim.ssbo_injections)
		graphics.unload_compute_shader(&fluid_sim.compute_shader_loaded)
		graphics.unload_shader(&fluid_sim.visualize_simple_shader_loaded)
		graphics.unload_texture(&fluid_sim.draw_texture)
	}
	fluid_sim.destroyed = true
}

init_simple :: proc(#any_int width, height: int, k, v, w: f32) -> FluidSim {
	fluid_sim := FluidSim{}

	assert(
		width % LOCAL_COMPUTE_SIZE == 0,
		fmt.tprintf("width modulo LOCAL_COMPUTE_SIZE(%d) must be 0", LOCAL_COMPUTE_SIZE),
	)

	size := width * height
	buffer_size: uint = uint(size_of(f32) * 4 * size)
	injections_size: uint = uint(size_of(Injection) * MAX_INJECTION)

	arena_reservation := (buffer_size * 3) + injections_size // 176mb

	err := virtual.arena_init_static(&fluid_sim.arena, arena_reservation)
	if err != nil {
		log.panicf("error allocating memory :: [%v]", err)
	}
	fluid_sim.alloc = virtual.arena_allocator(&fluid_sim.arena)
	data_a := make([dynamic][4]f32, size, size, fluid_sim.alloc)
	data_b := make([dynamic][4]f32, size, size, fluid_sim.alloc)
	data_read := make([dynamic][4]f32, size, size, fluid_sim.alloc) // @hack
	injections := make([dynamic]Injection, MAX_INJECTION, MAX_INJECTION, fluid_sim.alloc)

	ssbo_a := graphics.create_ssbo(buffer_size, &data_a[0], .DYNAMIC_COPY)
	ssbo_b := graphics.create_ssbo(buffer_size, &data_b[0], .DYNAMIC_COPY)
	ssbo_injections := graphics.create_ssbo(
		injections_size,
		&injections[0],
		.DYNAMIC_DRAW,
		"fluids_injections",
	)

	compute_shader_loaded := graphics.load_compute_shader(
		compute_simple_shader,
		"fluids_compute_simple",
	)
	visualize_simple_shader_loaded := graphics.load_shader(
		visualize_simple_shader,
		"fluids_visualize_simple",
	)

	draw_texture := graphics.create_texture(width, height)

	fluid_sim.simulation_type = .SIMPLE
	fluid_sim.width = width
	fluid_sim.height = height
	fluid_sim.size = size
	fluid_sim.buffer_size = buffer_size
	fluid_sim.k = k
	fluid_sim.v = v
	fluid_sim.w = w
	fluid_sim.ssbo_a = ssbo_a
	fluid_sim.ssbo_b = ssbo_b
	fluid_sim.data_read = data_read
	fluid_sim.ssbo_injections = ssbo_injections
	fluid_sim.data_a = data_a
	fluid_sim.data_b = data_b
	fluid_sim.compute_shader_loaded = compute_shader_loaded
	fluid_sim.visualize_simple_shader_loaded = visualize_simple_shader_loaded
	fluid_sim.injections = injections
	fluid_sim.draw_texture = draw_texture
	fluid_sim.destroyed = false

	clear(&fluid_sim.injections)
	return fluid_sim
}

init :: proc(#any_int width, height: int, k, v, w: f32) -> FluidSim {
	fluid_sim := FluidSim{}

	assert(
		width % LOCAL_COMPUTE_SIZE == 0,
		fmt.tprintf("width modulo LOCAL_COMPUTE_SIZE(%v) must be 0", LOCAL_COMPUTE_SIZE),
	)

	size := width * height
	buffer_size: uint = uint(size_of(f32) * 4 * size)
	injections_size: uint = uint(size_of(Injection) * MAX_INJECTION)
	divergence_size: uint = uint(size_of(f32) * size)
	pressure_size: uint = uint(size_of(f32) * size)

	arena_reservation :=
		(buffer_size * 3) + injections_size + divergence_size + (pressure_size * 2) // 221 MB

	err := virtual.arena_init_static(&fluid_sim.arena, arena_reservation)
	if err != nil {
		log.panicf("error allocating memory :: [%v]", err)
	}
	fluid_sim.alloc = virtual.arena_allocator(&fluid_sim.arena)

	data_a := make([dynamic][4]f32, size, size, fluid_sim.alloc)
	data_b := make([dynamic][4]f32, size, size, fluid_sim.alloc)
	data_read := make([dynamic][4]f32, size, size, fluid_sim.alloc)
	injections := make([dynamic]Injection, MAX_INJECTION, MAX_INJECTION, fluid_sim.alloc)
	data_divergence := make([dynamic]f32, size, size, fluid_sim.alloc)
	data_pressure_a := make([dynamic]f32, size, size, fluid_sim.alloc)
	data_pressure_b := make([dynamic]f32, size, size, fluid_sim.alloc)

	ssbo_a := graphics.create_ssbo(buffer_size, &data_a[0], .DYNAMIC_COPY)
	ssbo_b := graphics.create_ssbo(buffer_size, &data_b[0], .DYNAMIC_COPY)
	ssbo_injections := graphics.create_ssbo(
		injections_size,
		&injections[0],
		.DYNAMIC_DRAW,
		"fluids_injections",
	)
	ssbo_divergence := graphics.create_ssbo(
		divergence_size,
		&data_divergence[0],
		.DYNAMIC_COPY,
		"fluids_divergence",
	)
	ssbo_pressure_a := graphics.create_ssbo(pressure_size, &data_pressure_a[0], .DYNAMIC_COPY)
	ssbo_pressure_b := graphics.create_ssbo(pressure_size, &data_pressure_b[0], .DYNAMIC_COPY)

	// Load shaders into memory
	compute_shader_loaded := graphics.load_compute_shader(compute_shader, "fluids_compute")
	visualize_shader_loaded := graphics.load_shader(visualize_shader, "fluids_visualize")
	divergence_shader_loaded := graphics.load_compute_shader(
		divergence_shader,
		"fluids_divergence",
	)
	jacobi_shader_loaded := graphics.load_compute_shader(jacobi_shader, "jacobi_shader")
	gradient_shader_loaded := graphics.load_compute_shader(gradient_shader, "fluids_gradient")
	boundary_shader_loaded := graphics.load_compute_shader(boundary_shader, "fluids_boundary")

	draw_texture := graphics.create_texture(width, height)

	fluid_sim.simulation_type = .ACCURATE
	fluid_sim.width = width
	fluid_sim.height = height
	fluid_sim.size = size
	fluid_sim.buffer_size = buffer_size
	fluid_sim.k = k
	fluid_sim.v = v
	fluid_sim.w = w
	fluid_sim.ssbo_a = ssbo_a
	fluid_sim.ssbo_b = ssbo_b
	fluid_sim.data_read = data_read
	fluid_sim.ssbo_divergence = ssbo_divergence
	fluid_sim.ssbo_injections = ssbo_injections
	fluid_sim.data_a = data_a
	fluid_sim.data_b = data_b
	fluid_sim.data_pressure_a = data_pressure_a
	fluid_sim.data_pressure_b = data_pressure_b
	fluid_sim.ssbo_pressure_a = ssbo_pressure_a
	fluid_sim.ssbo_pressure_b = ssbo_pressure_b
	fluid_sim.data_divergence = data_divergence
	fluid_sim.compute_shader_loaded = compute_shader_loaded
	fluid_sim.divergence_shader_loaded = divergence_shader_loaded
	fluid_sim.visualize_shader_loaded = visualize_shader_loaded
	fluid_sim.jacobi_shader_loaded = jacobi_shader_loaded
	fluid_sim.gradient_shader_loaded = gradient_shader_loaded
	fluid_sim.boundary_shader_loaded = boundary_shader_loaded
	fluid_sim.injections = injections
	fluid_sim.draw_texture = draw_texture
	fluid_sim.destroyed = false

	clear(&fluid_sim.injections)
	return fluid_sim
}

step :: proc(fluid_sim: ^FluidSim, dt: f32) {
	if fluid_sim.simulation_type == .ACCURATE {

		delta: f32 = dt * DELTA_COEFFICIENT

		workgroups_x := fluid_sim.width / LOCAL_COMPUTE_SIZE
		workgroups_y := fluid_sim.height / LOCAL_COMPUTE_SIZE

		num_injections := len(fluid_sim.injections)
		graphics.begin_compute_shader(fluid_sim.compute_shader_loaded)
		if num_injections > 0 {
			graphics.update_ssbo(
				fluid_sim.ssbo_injections,
				&fluid_sim.injections[0],
				uint(num_injections * size_of(Injection)),
			)
		}

		graphics.bind_ssbo(fluid_sim.ssbo_a, 0)
		graphics.bind_ssbo(fluid_sim.ssbo_b, 1)
		graphics.bind_ssbo(fluid_sim.ssbo_injections, 2)
		graphics.set_compute_shader_uniform(0, &fluid_sim.width, .INT)
		graphics.set_compute_shader_uniform(1, &fluid_sim.height, .INT)
		graphics.set_compute_shader_uniform(2, &delta, .FLOAT)
		graphics.set_compute_shader_uniform(3, &fluid_sim.k, .FLOAT)
		graphics.set_compute_shader_uniform(4, &fluid_sim.v, .FLOAT)
		graphics.set_compute_shader_uniform(5, &fluid_sim.w, .FLOAT)
		graphics.set_compute_shader_uniform(6, &num_injections, .INT)
		graphics.dispatch_compute_shader(workgroups_x, workgroups_y)
		graphics.end_compute_shader()

		graphics.begin_compute_shader(fluid_sim.divergence_shader_loaded)
		graphics.bind_ssbo(fluid_sim.ssbo_b, 0)
		graphics.bind_ssbo(fluid_sim.ssbo_divergence, 1)
		graphics.set_compute_shader_uniform(0, &fluid_sim.width, .INT)
		graphics.set_compute_shader_uniform(1, &fluid_sim.height, .INT)
		graphics.dispatch_compute_shader(workgroups_x, workgroups_y)
		graphics.end_compute_shader()

		for _ in 0 ..< JACOBI_ITERATIONS {
			graphics.begin_compute_shader(fluid_sim.jacobi_shader_loaded)
			graphics.bind_ssbo(fluid_sim.ssbo_divergence, 0)
			graphics.bind_ssbo(fluid_sim.ssbo_pressure_a, 1)
			graphics.bind_ssbo(fluid_sim.ssbo_pressure_b, 2)
			graphics.set_compute_shader_uniform(0, &fluid_sim.width, .INT)
			graphics.set_compute_shader_uniform(1, &fluid_sim.height, .INT)
			graphics.dispatch_compute_shader(workgroups_x, workgroups_y)
			graphics.end_compute_shader()
			fluid_sim.ssbo_pressure_a, fluid_sim.ssbo_pressure_b =
				fluid_sim.ssbo_pressure_b, fluid_sim.ssbo_pressure_a
		}

		graphics.begin_compute_shader(fluid_sim.gradient_shader_loaded)
		graphics.bind_ssbo(fluid_sim.ssbo_b, 0)
		graphics.bind_ssbo(fluid_sim.ssbo_pressure_a, 1)
		graphics.set_compute_shader_uniform(0, &fluid_sim.width, .INT)
		graphics.set_compute_shader_uniform(1, &fluid_sim.height, .INT)
		graphics.dispatch_compute_shader(workgroups_x, workgroups_y)
		graphics.end_compute_shader()

		graphics.begin_compute_shader(fluid_sim.boundary_shader_loaded)
		graphics.bind_ssbo(fluid_sim.ssbo_b, 0)
		graphics.set_compute_shader_uniform(0, &fluid_sim.width, .INT)
		graphics.set_compute_shader_uniform(1, &fluid_sim.height, .INT)
		graphics.dispatch_compute_shader(workgroups_x, workgroups_y)
		graphics.end_compute_shader()

		fluid_sim.ssbo_a, fluid_sim.ssbo_b = fluid_sim.ssbo_b, fluid_sim.ssbo_a
	} else {
		delta: f32 = dt * DELTA_COEFFICIENT

		workgroups_x := fluid_sim.width / LOCAL_COMPUTE_SIZE
		workgroups_y := fluid_sim.height / LOCAL_COMPUTE_SIZE

		num_injections := len(fluid_sim.injections)
		graphics.begin_compute_shader(fluid_sim.compute_shader_loaded)
		if num_injections > 0 {
			graphics.update_ssbo(
				fluid_sim.ssbo_injections,
				&fluid_sim.injections[0],
				uint(num_injections * size_of(Injection)),
			)
		}

		graphics.bind_ssbo(fluid_sim.ssbo_a, 0)
		graphics.bind_ssbo(fluid_sim.ssbo_b, 1)
		graphics.bind_ssbo(fluid_sim.ssbo_injections, 2)
		graphics.set_compute_shader_uniform(0, &fluid_sim.width, .INT)
		graphics.set_compute_shader_uniform(1, &fluid_sim.height, .INT)
		graphics.set_compute_shader_uniform(2, &delta, .FLOAT)
		graphics.set_compute_shader_uniform(3, &fluid_sim.k, .FLOAT)
		graphics.set_compute_shader_uniform(4, &fluid_sim.v, .FLOAT)
		graphics.set_compute_shader_uniform(5, &fluid_sim.w, .FLOAT)
		graphics.set_compute_shader_uniform(6, &num_injections, .INT)
		graphics.dispatch_compute_shader(workgroups_x, workgroups_y)
		graphics.end_compute_shader()

		fluid_sim.ssbo_a, fluid_sim.ssbo_b = fluid_sim.ssbo_b, fluid_sim.ssbo_a
	}
}

draw :: proc(fluid_sim: ^FluidSim) {
	if fluid_sim.simulation_type == .ACCURATE {
		graphics.begin_texture(fluid_sim.draw_texture)
		graphics.begin_shader(fluid_sim.visualize_shader_loaded)
		graphics.bind_ssbo(fluid_sim.ssbo_a, 0)
		graphics.set_shader_uniform(fluid_sim.visualize_shader_loaded, 0, .INT, &fluid_sim.width)
		graphics.set_shader_uniform(fluid_sim.visualize_shader_loaded, 1, .INT, &fluid_sim.height)
		graphics.rect(fluid_sim.width, fluid_sim.height)
		graphics.end_shader()
		graphics.end_texture()
	} else {
		graphics.begin_texture(fluid_sim.draw_texture)
		graphics.begin_shader(fluid_sim.visualize_simple_shader_loaded)
		graphics.bind_ssbo(fluid_sim.ssbo_a, 0)
		graphics.set_shader_uniform(
			fluid_sim.visualize_simple_shader_loaded,
			0,
			.INT,
			&fluid_sim.width,
		)
		graphics.set_shader_uniform(
			fluid_sim.visualize_simple_shader_loaded,
			1,
			.INT,
			&fluid_sim.height,
		)
		graphics.rect(fluid_sim.width, fluid_sim.height)
		graphics.end_shader()
		graphics.end_texture()
	}
}

read :: proc(fluid_sim: ^FluidSim) {
	graphics.read_ssbo(fluid_sim.ssbo_a, &fluid_sim.data_read[0], fluid_sim.buffer_size)
}

push_injection :: proc(fluid_sim: ^FluidSim, injection: Injection) {
	assert(
		len(fluid_sim.injections) < MAX_INJECTION,
		fmt.tprintf(
			"Cannot push more than %d injections into the fluid simulation",
			MAX_INJECTION,
		),
	)
	if len(fluid_sim.injections) < MAX_INJECTION {
		_, err := append(&fluid_sim.injections, injection)
		assert(err == nil, fmt.tprintf("Could not allocate memory :: %v", err))
	}
}

clear_injections :: proc(fluid_sim: ^FluidSim) {
	clear(&fluid_sim.injections)
}
