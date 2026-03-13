package graphics

import "core:c"
import "core:fmt"
import "vendor:raylib"
import "vendor:raylib/rlgl"

Texture :: raylib.RenderTexture
Shader :: raylib.Shader

Color :: struct {
	r, g, b, a: f32,
}

to_u8 :: proc(color: Color) -> [4]u8 {
	return [4]u8{u8(color.r * 255), u8(color.g * 255), u8(color.b * 255), u8(color.a * 255)}
}

to_rl :: proc(color: Color) -> raylib.Color {
	return raylib.Color(to_u8(color))
}

// Functions as a hint to the GPU driver on what the SSBO will be used for
// Is only a hint, does not have to be respected by the GPU driver, if it is respected and used correctly
// the performance boost can be significant
// DYNAMIC_DRAW = CPU updates often, GPU reads it
// DYNAMIC_READ = GPU updates often, CPU reads it
// DYNAMIC_COPY = GPU writes it often, GPU reads it later, CPU does not touch it
SSBO_TYPE :: enum {
	DYNAMIC_COPY,
	DYNAMIC_READ,
	DYNAMIC_DRAW,
}

@(private)
SSBO_TYPE_MAPPING := [SSBO_TYPE]c.int {
	.DYNAMIC_COPY = rlgl.DYNAMIC_COPY,
	.DYNAMIC_READ = rlgl.DYNAMIC_READ,
	.DYNAMIC_DRAW = rlgl.DYNAMIC_DRAW,
}


// Dispatches a compute shader with the provided amount of workgroups
dispatch_compute_shader :: proc(#any_int workgroups_x, workgroups_y: int) {
	rlgl.ComputeShaderDispatch(u32(workgroups_x), u32(workgroups_y), 1)
}

// Creates a shader buffer
// Backing data must be a pointer to the first element of an array
// Panics if the SSBO cannot be created
create_ssbo :: proc(
	size: uint,
	backing_data: ^$T,
	type: SSBO_TYPE,
	identifier: string = "identifier not provided",
) -> uint {
	ssbo := rlgl.LoadShaderBuffer(u32(size), backing_data, SSBO_TYPE_MAPPING[type])
	assert(ssbo > 0, fmt.tprintf("Error creating SSBO :: [%v]", identifier))
	return uint(ssbo)
}

unload_ssbo :: proc(ssbo: ^uint) {
	rlgl.UnloadShaderBuffer(u32(ssbo^))
	ssbo^ = 0
}

// Updates an SSBO, sending new data to the GPU
// Must be called when updating contents of an SSBO
// Updating the backing data is NOT ENOUGH
update_ssbo :: proc(ssbo: uint, backing_data: ^$T, size: uint) {
	rlgl.UpdateShaderBuffer(u32(ssbo), backing_data, u32(size), 0)

}

// Reads out an SSBO back into the CPU
// !!VERY SLOW!!
read_ssbo :: proc(ssbo: uint, read_out: ^$T, size: uint) {
	rlgl.ReadShaderBuffer(u32(ssbo), read_out, u32(size), 0)
}

// Binds a shader buffer to the currently active shader
// Works for both fragment shaders and compute shaders
bind_ssbo :: proc(ssbo: uint, loc: uint) {
	rlgl.BindShaderBuffer(u32(ssbo), u32(loc))
}

// Loads a fragment shader from memory
// Will panic if compilation or linking fails
load_shader :: proc(code: cstring, identifier: string = "identifier not provided") -> Shader {
	shader := raylib.LoadShaderFromMemory(nil, code)
	assert(shader.id > 0, fmt.tprintf("Failed compiling shader :: [%v]", identifier))
	return shader
}

unload_shader :: proc(shader: ^Shader) {
	raylib.UnloadShader(shader^)
	shader^ = Shader{}
}

// Binds a fragment shader
// Uniform and buffer binding must happen after this call
begin_shader :: proc(shader: raylib.Shader) {
	raylib.BeginShaderMode(shader)
}

// Unbinds a fragment shader
// Must be called before starting another shader
end_shader :: proc() {
	raylib.EndShaderMode()
}

// Loads a compute shader from memory
// Will panic if compilation or linking fails
load_compute_shader :: proc(
	code: cstring,
	identifier: string = "no identifier provided",
) -> Shader {
	compute_shader := rlgl.CompileShader(code, rlgl.COMPUTE_SHADER)
	compute_program := rlgl.LoadComputeShaderProgram(compute_shader)
	assert(compute_shader > 0, fmt.tprintf("Error compiling shader :: [%v]", identifier))
	assert(compute_program > 0, fmt.tprintf("Error linking shader :: [%v]", identifier))
	return Shader{id = u32(compute_program)}
}

unload_compute_shader :: proc(shader: ^Shader) {
	rlgl.UnloadShaderProgram(shader^.id)
	shader^ = Shader{}
}

// Binds a compute shader
// Uniform and buffer binding must happen after this call
begin_compute_shader :: proc(shader: Shader) {
	rlgl.EnableShader(shader.id)
}

// Unbinds a compute shader
end_compute_shader :: proc() {
	rlgl.DisableShader()
}

// Sets a shader uniform at the given location
// Prefer setting uniform locations manually with layout(location = x) if OpenGL 4.3 is available
set_shader_uniform :: proc(
	shader: raylib.Shader,
	#any_int location: int,
	uniform_type: rlgl.ShaderUniformDataType,
	val: ^$T,
) {
	raylib.SetShaderValue(shader, location, rawptr(val), uniform_type)
}

// Sets a compute shader uniform at the given location
// Prefer setting uniform locations manually with layout(location = x) if OpenGL 4.3 is available
set_compute_shader_uniform :: proc(
	#any_int location: int,
	val: ^$T,
	uniform_type: rlgl.ShaderUniformDataType,
) {
	rlgl.SetUniform(i32(location), val, i32(uniform_type), 1)
}

// Sets a shader texture at the given location
// Prefer setting uniform locations manually with layout(location = x) if OpenGL 4.3 is available
set_shader_texture :: proc(shader: raylib.Shader, #any_int location: int, texture: Texture) {
	raylib.SetShaderValueTexture(shader, location, texture.texture)
}

// Creates a texture that is ready for rendering
create_texture :: proc(
	#any_int width, height: int,
	format: rlgl.PixelFormat = rlgl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	backing_data: rawptr = nil,
	#any_int mipmaps: int = 1,
) -> Texture {
	target: Texture
	target.id = rlgl.LoadFramebuffer()
	assert(target.id > 0, "FBO: Framebuffer object cannot be created")
	rlgl.EnableFramebuffer(target.id)
	target.texture.id = rlgl.LoadTexture(backing_data, i32(width), i32(height), i32(format), 1)
	target.texture.width = i32(width)
	target.texture.height = i32(height)
	target.texture.format = format
	target.texture.mipmaps = i32(mipmaps)
	target.depth.id = rlgl.LoadTextureDepth(i32(width), i32(height), true)
	target.depth.width = i32(width)
	target.depth.height = i32(height)
	target.depth.mipmaps = i32(mipmaps)


	rlgl.FramebufferAttach(
		target.id,
		target.texture.id,
		i32(rlgl.FramebufferAttachType.COLOR_CHANNEL0),
		i32(rlgl.FramebufferAttachTextureType.TEXTURE2D),
		0,
	)
	rlgl.FramebufferAttach(
		target.id,
		target.depth.id,
		i32(rlgl.FramebufferAttachType.DEPTH),
		i32(rlgl.FramebufferAttachTextureType.RENDERBUFFER),
		0,
	)

	raylib.SetTextureFilter(target.texture, .BILINEAR)
	raylib.SetTextureWrap(target.texture, .CLAMP)
	return target
}

unload_texture :: proc(texture: ^Texture) {
	raylib.UnloadTexture(texture.texture)
	texture^ = Texture{}
}

// Begins texture mode
begin_texture :: proc(texture: Texture, background_color: Color = Color{0, 0, 0, 1}) {
	raylib.BeginTextureMode(texture)
	raylib.ClearBackground(to_rl(background_color))
}

// Ends texture mode
end_texture :: proc() {
	raylib.EndTextureMode()
}

// Begins frame buffer mode
begin_drawing :: proc(background_color: Color = Color{0, 0, 0, 1}) {
	raylib.BeginDrawing()
	raylib.ClearBackground(to_rl(background_color))
}

// Ends frame buffer mode
end_drawing :: proc() {
	raylib.EndDrawing()
}

// Draws a rectangle to the screen
// To be used for full screen fragment shader passes
rect :: proc(#any_int width, height: int, _color: Color = Color{0, 0, 0, 1}) {
	raylib.DrawRectangle(0, 0, i32(width), i32(height), to_rl(_color))
}

// Draws a texture rectangle to the screen
texture_rect :: proc(#any_int width, height: int, scene: Texture) {
	source := raylib.Rectangle {
		x      = 0,
		y      = 0,
		width  = f32(scene.texture.width),
		height = -f32(scene.texture.height),
	}
	dest := raylib.Rectangle {
		x      = 0,
		y      = 0,
		width  = f32(width),
		height = f32(height),
	}
	raylib.DrawTexturePro(scene.texture, source, dest, [2]f32{0, 0}, 0, raylib.WHITE)
}
