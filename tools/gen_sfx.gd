extends SceneTree
## Dev tool: synthesize the placeholder SFX set as .wav files.
## Run once: godot --headless -s res://tools/gen_sfx.gd

const SR: int = 22050


func _init() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sfx")
	seed(7)
	_write("shot", _gun(0.14, 0.45, 1.8))
	_write("shot_smg", _gun(0.09, 0.6, 2.2))
	_write("shot_shotgun", _gun(0.25, 0.3, 1.4))
	_write("laser", _laser())
	_write("boom", _boom())
	_write("hit", _hit())
	_write("dodge", _whoosh())
	_write("heal", _chime())
	_write("flame", _crackle())
	_write("flash", _flashbang())
	_write("latch", _squelch())
	print("[sfx] done")
	quit()


func _env(i: int, n: int, attack: float, release: float) -> float:
	var t: float = float(i) / float(n)
	if t < attack:
		return t / attack
	return pow(maxf(0.0, 1.0 - (t - attack) / (1.0 - attack)), release)


func _write(sfx_name: String, samples: PackedFloat32Array) -> void:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i: int in samples.size():
		var v: int = clampi(int(samples[i] * 32767.0), -32767, 32767)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SR
	wav.stereo = false
	wav.data = data
	wav.save_to_wav("res://assets/sfx/%s.wav" % sfx_name)
	print("[sfx] ", sfx_name, " ", samples.size())


func _gun(dur: float, mix: float, rel: float) -> PackedFloat32Array:
	var n: int = int(SR * dur)
	var out := PackedFloat32Array()
	var prev: float = 0.0
	for i: int in n:
		var x: float = randf_range(-1, 1) * _env(i, n, 0.005, rel)
		prev = prev * (1.0 - mix) + x * mix
		out.append(prev * 0.9)
	return out


func _laser() -> PackedFloat32Array:
	var n: int = int(SR * 0.35)
	var out := PackedFloat32Array()
	for i: int in n:
		var t: float = float(i) / SR
		var f: float = 300.0 + 2200.0 * pow(float(i) / n, 2.0)
		out.append(0.6 * sin(TAU * f * t) * _env(i, n, 0.02, 0.8))
	return out


func _boom() -> PackedFloat32Array:
	var n: int = int(SR * 0.5)
	var out := PackedFloat32Array()
	var prev: float = 0.0
	for i: int in n:
		var x: float = randf_range(-1, 1) * _env(i, n, 0.005, 1.2)
		prev = prev * 0.88 + x * 0.12
		out.append(prev * 1.4 + 0.3 * sin(TAU * 55.0 * float(i) / SR) * _env(i, n, 0.01, 1.5))
	return out


func _hit() -> PackedFloat32Array:
	var n: int = int(SR * 0.08)
	var out := PackedFloat32Array()
	for i: int in n:
		var t: float = float(i) / SR
		out.append(0.7 * sin(TAU * (180.0 - 120.0 * float(i) / n) * t) * _env(i, n, 0.005, 1.5))
	return out


func _whoosh() -> PackedFloat32Array:
	var n: int = int(SR * 0.18)
	var out := PackedFloat32Array()
	var prev: float = 0.0
	for i: int in n:
		prev = prev * 0.92 + randf_range(-1, 1) * 0.08
		out.append(prev * 1.2 * sin(PI * float(i) / n))
	return out


func _chime() -> PackedFloat32Array:
	var n: int = int(SR * 0.4)
	var out := PackedFloat32Array()
	for i: int in n:
		var t: float = float(i) / SR
		out.append(0.35 * (sin(TAU * 660.0 * t) + 0.6 * sin(TAU * 880.0 * t)) * _env(i, n, 0.05, 1.0))
	return out


func _crackle() -> PackedFloat32Array:
	var n: int = int(SR * 0.6)
	var out := PackedFloat32Array()
	var prev: float = 0.0
	for i: int in n:
		var x: float = randf_range(-1, 1) * (0.5 + 0.5 * sin(TAU * 7.0 * float(i) / SR))
		prev = prev * 0.8 + x * 0.2
		out.append(prev * 0.8 * _env(i, n, 0.1, 0.5))
	return out


func _flashbang() -> PackedFloat32Array:
	var n: int = int(SR * 0.45)
	var out := PackedFloat32Array()
	var prev: float = 0.0
	for i: int in n:
		var t: float = float(i) / SR
		prev = prev * 0.6 + randf_range(-1, 1) * 0.3 * 0.4
		out.append((0.55 * sin(TAU * 1400.0 * t) + prev) * _env(i, n, 0.003, 1.6))
	return out


func _squelch() -> PackedFloat32Array:
	var n: int = int(SR * 0.22)
	var out := PackedFloat32Array()
	var prev: float = 0.0
	for i: int in n:
		var t: float = float(i) / SR
		prev = prev * 0.85 + randf_range(-1, 1) * 0.15
		out.append(prev * 0.9 * sin(TAU * (90.0 + 60.0 * sin(TAU * 18.0 * t)) * t) * _env(i, n, 0.02, 0.9))
	return out