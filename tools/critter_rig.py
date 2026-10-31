"""Shared Blender side for the newer creature sheets (borer, mite, broodmother).

The same set-up as tools/crawler_blender.py, wrapped up for reuse: the miner's scale
(80 px per 3.625 units), an orthographic side camera looking along +Y (creatures face +X),
the sun from upper left, crisp unfiltered pixels and three passes per frame: flat colours
(albedo), white clay (lighting) and camera normals. Materials named in `glow` stay bright in
the clay pass; their flat colours are picked out again by tools/critter_sheet.py for the
unshaded pixels and the _glow.png bloom layer.

Joint convention (as the crawler / miner): every joint turns about Y and setrot(j, deg) turns
it `deg` degrees counter-clockwise on screen.
"""
import math
import os

import bpy
from mathutils import Vector

from normal_pass import PASSES, normal_shader, set_view

PX_PER_UNIT = 80 / 3.625      # the miner's scale
NEAR, FAR = -1, 1             # camera at -Y: -Y is the near side


class Rig:
    def __init__(self, cell_w, cell_h, feet_below_center, colors, glow=(), cam_x=0.0, samples=48):
        self.cell_w, self.cell_h = cell_w, cell_h
        self.colors = colors
        self.glow = set(glow)
        self.mats = {}
        self.meshes = []
        bpy.ops.wm.read_factory_settings(use_empty=True)
        scene = self.scene = bpy.context.scene
        scene.render.engine = "CYCLES"
        scene.cycles.device = "CPU"
        scene.cycles.samples = samples
        scene.cycles.use_denoising = False
        scene.cycles.filter_width = 0.01           # no anti-aliasing: crisp pixels
        scene.render.film_transparent = True
        scene.render.resolution_x = cell_w
        scene.render.resolution_y = cell_h
        scene.render.resolution_percentage = 100
        scene.render.image_settings.file_format = "PNG"
        scene.render.image_settings.color_mode = "RGBA"
        scene.view_settings.view_transform = "Standard"
        self.world = bpy.data.worlds.new("W")
        scene.world = self.world
        self.world.use_nodes = True
        self.world.node_tree.nodes["Background"].inputs[0].default_value = (0.12, 0.12, 0.12, 1)
        cam_data = bpy.data.cameras.new("Cam")
        cam_data.type = "ORTHO"
        cam_data.ortho_scale = max(cell_w, cell_h) / PX_PER_UNIT
        cam = bpy.data.objects.new("Cam", cam_data)
        scene.collection.objects.link(cam)
        cam.location = (cam_x, -10, feet_below_center / PX_PER_UNIT)
        cam.rotation_euler = (math.radians(90), 0, 0)
        scene.camera = cam
        self.sun_data = bpy.data.lights.new("Sun", "SUN")
        self.sun_data.energy = 1.4
        self.sun_data.angle = math.radians(2)
        sun = bpy.data.objects.new("Sun", self.sun_data)
        scene.collection.objects.link(sun)
        sun.rotation_euler = (-Vector((0.55, 0.75, -0.8)).normalized()).to_track_quat("Z", "Y").to_euler()

    # ------------------------------------------------------------ materials
    @staticmethod
    def hex_rgb(h):
        h = h.lstrip("#")
        return [(int(h[i:i + 2], 16) / 255) ** 2.2 for i in (0, 2, 4)] + [1.0]

    def material(self, name):
        if name in self.mats:
            return self.mats[name]
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        em = nt.nodes.new("ShaderNodeEmission")
        em.inputs["Color"].default_value = self.hex_rgb(self.colors[name])
        if name in self.glow:
            df = nt.nodes.new("ShaderNodeEmission")
            df.inputs["Strength"].default_value = 3.0
        else:
            df = nt.nodes.new("ShaderNodeBsdfDiffuse")
            df.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
        self.mats[name] = (m, nt, out, em, df, normal_shader(nt))
        nt.links.new(em.outputs[0], out.inputs["Surface"])
        return self.mats[name]

    def set_mode(self, mode):
        for m, nt, out, em, df, nm in self.mats.values():
            for l in list(out.inputs["Surface"].links):
                nt.links.remove(l)
            nt.links.new({"flat": em, "clay": df, "normal": nm}[mode].outputs[0], out.inputs["Surface"])
        self.world.node_tree.nodes["Background"].inputs[1].default_value = 1.0 if mode == "clay" else 0.0
        self.sun_data.energy = 1.4 if mode == "clay" else 0.0
        set_view(self.scene, mode)

    def swap(self, obj, mat):
        """Give a mesh another material (e.g. eyes going dark when it dies)."""
        obj.data.materials[0] = self.material(mat)[0]

    # ------------------------------------------------------------ modelling
    def finish(self, obj, mat, smooth=False):
        obj.data.materials.append(self.material(mat)[0])
        if smooth:
            for p in obj.data.polygons:
                p.use_smooth = True
        self.meshes.append(obj)
        return obj

    def joint(self, name, parent, loc):
        e = bpy.data.objects.new(name, None)
        self.scene.collection.objects.link(e)
        e.location = loc
        e.rotation_mode = "XYZ"
        if parent:
            e.parent = parent
            e.matrix_parent_inverse = parent.matrix_world.inverted()
        bpy.context.view_layer.update()
        return e

    @staticmethod
    def attach(obj, parent):
        bpy.context.view_layer.update()
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()

    def _done(self, name, mat, parent, smooth=False):
        o = bpy.context.active_object
        o.name = name
        self.finish(o, mat, smooth)
        self.attach(o, parent)
        return o

    def cyl(self, name, loc, radius, depth, mat, parent, verts=8, rot=(0, 0, 0), scale=(1, 1, 1)):
        bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth, location=loc, rotation=rot)
        bpy.context.active_object.scale = scale
        return self._done(name, mat, parent, verts > 8)

    def cone(self, name, loc, r1, depth, mat, parent, rot=(0, 0, 0), verts=6, tip=0.0):
        """Cone with its point (radius `tip`) down (-Z) unless rotated."""
        bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=tip, radius2=r1, depth=depth, location=loc,
                                        rotation=rot)
        return self._done(name, mat, parent)

    def ball(self, name, loc, radius, mat, parent, scale=(1, 1, 1), segs=12, rings=8):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=rings, radius=radius, location=loc)
        bpy.context.active_object.scale = scale
        return self._done(name, mat, parent, True)

    def box(self, name, loc, size, mat, parent, rot=(0, 0, 0)):
        bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
        bpy.context.active_object.scale = size
        return self._done(name, mat, parent)

    def limb(self, name, a, b, r0, r1, mat, parent, verts=6):
        """A tapered rod from point a (radius r0) to point b (radius r1), in rest-pose world space."""
        a, b = Vector(a), Vector(b)
        d = (b - a).length
        bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r0, depth=d,
                                        location=(a + b) / 2)
        o = bpy.context.active_object
        v = (b - a).normalized()
        o.rotation_euler = (-v).to_track_quat("Z", "Y").to_euler()   # radius1 (r1) end at b
        return self._done(name, mat, parent)

    # ------------------------------------------------------------ posing
    @staticmethod
    def setrot(obj, deg):
        obj.rotation_euler = (0, math.radians(-deg), 0)

    @staticmethod
    def world_angle(obj):
        m = obj.matrix_world
        return -math.degrees(math.atan2(m[0][2], m[0][0]))

    @staticmethod
    def two_bone(dx, dz, l1, l2, bend):
        """(first bone angle, joint bend) reaching offset (dx, dz) from the hip."""
        d = max(min(math.hypot(dx, dz), l1 + l2 - 1e-4), abs(l1 - l2) + 1e-4)
        phi = math.degrees(math.atan2(dx, -dz))
        alpha = math.degrees(math.acos((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)))
        inner = math.degrees(math.acos((l1 * l1 + l2 * l2 - d * d) / (2 * l1 * l2)))
        return phi - bend * alpha, bend * (180 - inner)

    def low_z(self):
        bpy.context.view_layer.update()
        return min((o.matrix_world @ v.co).z for o in self.meshes if not o.hide_render for v in o.data.vertices)

    def render(self, out_dir, name, i):
        bpy.context.view_layer.update()
        for mode in PASSES:
            self.set_mode(mode)
            self.scene.render.filepath = os.path.join(out_dir, f"{name}_{i}_{mode}.png")
            bpy.ops.render.render(write_still=True)
