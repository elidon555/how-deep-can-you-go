"""Blender side of the normal maps, shared by every *_blender.py script.

Each material gets a third shader next to its flat (albedo) and clay (lighting) ones: an
emission whose colour is the surface normal in camera space (x right, y up, z toward the
camera) packed into 0..1. Rendered with the "Raw" view transform so the PNG holds those
values untouched; tools/normal_maps.py turns them into the game's normal maps.
"""
import bpy

PASSES = ("flat", "clay", "normal")


def normal_shader(nt):
    """Add the camera-space normal emission to a material's node tree and return it."""
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    vt = nt.nodes.new("ShaderNodeVectorTransform")
    vt.vector_type = "NORMAL"
    vt.convert_from = "WORLD"
    vt.convert_to = "CAMERA"
    pack = nt.nodes.new("ShaderNodeVectorMath")
    pack.operation = "MULTIPLY_ADD"           # n * 0.5 + 0.5
    pack.inputs[1].default_value = (0.5, 0.5, 0.5)
    pack.inputs[2].default_value = (0.5, 0.5, 0.5)
    em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(geo.outputs["Normal"], vt.inputs[0])
    nt.links.new(vt.outputs[0], pack.inputs[0])
    nt.links.new(pack.outputs[0], em.inputs["Color"])
    return em


def set_view(scene, mode):
    """Normals must not be tone mapped; the colour passes keep the Standard view."""
    scene.view_settings.view_transform = "Raw" if mode == "normal" else "Standard"
