class_name Art
## Loads sprites the way Dead Cells lights its pre-rendered ones: if X_n.png (a normal map,
## rendered by the tools/*_sheet.py scripts) sits next to X.png, the texture comes back as a
## CanvasTexture with it, so in-game lights (headlamp, fire, lanterns) shade the sprite.
## Without one it's the plain texture.

static var _cache := {}


static func lit(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var tex: Texture2D = load(path)
	var n := normals_path(path)
	if ResourceLoader.exists(n):
		var ct := CanvasTexture.new()
		ct.diffuse_texture = tex
		ct.normal_texture = load(n)
		tex = ct
	_cache[path] = tex
	return tex


static func has_normals(path: String) -> bool:
	return ResourceLoader.exists(normals_path(path))


static func normals_path(path: String) -> String:
	return path.get_basename() + "_n." + path.get_extension()
