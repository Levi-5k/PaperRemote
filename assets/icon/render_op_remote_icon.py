"""Render the OP Remote app icon in Blender.

The icon is only the letters OP, large enough to fill the frame.

    /Applications/Blender.app/Contents/MacOS/Blender --background \
        --python assets/icon/render_op_remote_icon.py -- \
        --out paperGIF/Assets.xcassets/AppIcon.appiconset --size 1024
"""

import math
import os
import sys

import bpy


def args_after_double_dash():
    if "--" not in sys.argv:
        return []
    return sys.argv[sys.argv.index("--") + 1 :]


def parse_args():
    raw = args_after_double_dash()
    options = {
        "out": os.path.abspath("assets/icon"),
        "size": 1024,
        "only": None,
    }
    index = 0
    while index < len(raw):
        key = raw[index]
        if key == "--out":
            options["out"] = os.path.abspath(raw[index + 1])
            index += 2
        elif key == "--size":
            options["size"] = int(raw[index + 1])
            index += 2
        elif key == "--only":
            options["only"] = raw[index + 1]
            index += 2
        else:
            raise SystemExit(f"Unknown argument {key}")
    return options


FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

def principled(name, color, roughness=0.45, metallic=0.0, coat=0.0, emission=0.0):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    shader = material.node_tree.nodes["Principled BSDF"]
    shader.inputs["Base Color"].default_value = (*color, 1.0)
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    if "Weight" in shader.inputs:
        shader.inputs["Weight"].default_value = 1.0
    if "Subsurface Weight" in shader.inputs:
        shader.inputs["Subsurface Weight"].default_value = 0.0
    if "Coat Weight" in shader.inputs:
        shader.inputs["Coat Weight"].default_value = coat
    if "Emission Strength" in shader.inputs:
        shader.inputs["Emission Strength"].default_value = emission
        if emission and "Emission Color" in shader.inputs:
            shader.inputs["Emission Color"].default_value = (*color, 1.0)
    if "Specular IOR Level" in shader.inputs:
        shader.inputs["Specular IOR Level"].default_value = 0.55 if metallic else 0.32
    return material


def track_to(obj, target):
    constraint = obj.constraints.new("TRACK_TO")
    constraint.target = target
    constraint.track_axis = "TRACK_NEGATIVE_Z"
    constraint.up_axis = "UP_Y"


def area_light(name, location, energy, size, color, target):
    bpy.ops.object.light_add(type="AREA", location=location)
    light = bpy.context.active_object
    light.name = name
    light.data.energy = energy
    light.data.size = size
    light.data.color = color
    track_to(light, target)
    return light


def shade(obj):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_smooth()
    obj.select_set(False)


def rounded_box(name, size, bevel, location, material, parent):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    modifier = obj.modifiers.new("Bevel", "BEVEL")
    modifier.width = bevel
    modifier.segments = 3
    modifier.limit_method = "ANGLE"
    modifier.angle_limit = math.radians(40)
    modifier.harden_normals = True
    if hasattr(modifier, "use_clamp_overlap"):
        modifier.use_clamp_overlap = True
    shade(obj)
    obj.data.materials.append(material)
    obj.parent = parent
    return obj


def cylinder(name, radius, depth, location, material, parent, vertices=64):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices,
        radius=radius,
        depth=depth,
        location=location,
    )
    obj = bpy.context.active_object
    obj.name = name
    shade(obj)
    obj.data.materials.append(material)
    obj.parent = parent
    return obj


def op_letters(material, parent):
    bpy.ops.object.text_add(location=(0.0, 0.0, 0.0))
    text = bpy.context.active_object
    text.name = "OP"
    text.data.body = "OP"
    text.data.font = bpy.data.fonts.load(FONT)
    text.data.size = 1.0
    text.data.space_character = 0.88
    text.data.align_x = "CENTER"
    text.data.align_y = "CENTER"
    text.data.extrude = 0.045
    text.data.bevel_depth = 0.008
    text.data.bevel_resolution = 2
    text.data.resolution_u = 8
    text.data.fill_mode = "BOTH"
    text.data.materials.append(material)
    bpy.ops.object.convert(target="MESH")
    letters = bpy.context.active_object
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    width = max(letters.dimensions.x, 0.001)
    factor = 0.62 / width
    letters.scale = (factor, factor, factor)
    letters.location = (0.0, 0.40, 0.232)
    letters.parent = parent
    return letters


def configure_render(size):
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.compression = 15
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0
    eevee = getattr(scene, "eevee", None)
    if eevee is not None:
        if hasattr(eevee, "taa_render_samples"):
            eevee.taa_render_samples = 16
        if hasattr(eevee, "use_raytracing"):
            eevee.use_raytracing = False
        if hasattr(eevee, "use_shadows"):
            eevee.use_shadows = True


def solid_background(color):
    world = bpy.data.worlds.new("IconWorld")
    bpy.context.scene.world = world
    world.use_nodes = True
    nodes = world.node_tree.nodes
    links = world.node_tree.links
    background = nodes["Background"]
    background.inputs["Color"].default_value = (*color, 1.0)
    background.inputs["Strength"].default_value = 1.0
    lighting = nodes.new("ShaderNodeBackground")
    lighting.inputs["Color"].default_value = (0.85, 0.86, 0.84, 1.0)
    lighting.inputs["Strength"].default_value = 0.15
    light_path = nodes.new("ShaderNodeLightPath")
    mix = nodes.new("ShaderNodeMixShader")
    output = nodes["World Output"]
    links.new(light_path.outputs["Is Camera Ray"], mix.inputs["Fac"])
    links.new(lighting.outputs["Background"], mix.inputs[1])
    links.new(background.outputs["Background"], mix.inputs[2])
    surface = output.inputs["Surface"]
    for link in list(surface.links):
        links.remove(link)
    links.new(mix.outputs["Shader"], surface)


def build(theme):
    from mathutils import Vector

    bpy.ops.wm.read_factory_settings(use_empty=True)
    face = principled("Face", theme["face"], roughness=0.28, coat=0.18)
    side = principled("Side", theme["side"], roughness=0.35, metallic=0.25)

    bpy.ops.object.text_add(location=(0.0, 0.0, 0.0))
    text = bpy.context.active_object
    text.name = "OP"
    text.data.body = "OP"
    text.data.font = bpy.data.fonts.load(FONT)
    text.data.size = 1.0
    text.data.space_character = 0.84
    text.data.align_x = "CENTER"
    text.data.align_y = "CENTER"
    text.data.extrude = 0.32
    text.data.bevel_depth = 0.015
    text.data.bevel_resolution = 2
    text.data.resolution_u = 8
    text.data.fill_mode = "BOTH"
    text.data.materials.append(face)
    bpy.ops.object.convert(target="MESH")
    letters = bpy.context.active_object
    letters.data.materials.append(side)
    for poly in letters.data.polygons:
        poly.material_index = 0 if abs(poly.normal.z) > 0.55 else 1
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    letters.location = (0.0, 0.0, 0.0)
    letters.rotation_euler = (math.radians(12), math.radians(-14), 0.0)
    bpy.context.view_layer.update()

    def bounds(obj):
        pts = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
        return (
            min(p.x for p in pts),
            max(p.x for p in pts),
            min(p.y for p in pts),
            max(p.y for p in pts),
        )

    # Stretch vertically until OP nearly touches every edge of the square.
    min_x, max_x, min_y, max_y = bounds(letters)
    width = max(max_x - min_x, 0.001)
    height = max(max_y - min_y, 0.001)
    letters.scale = (1.0, (width * 0.94) / (height * 0.96), 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.context.view_layer.update()
    min_x, max_x, min_y, max_y = bounds(letters)
    letters.location = (-(min_x + max_x) / 2.0, -(min_y + max_y) / 2.0, 0.0)
    width = max_x - min_x
    height = max_y - min_y

    solid_background(theme["background"])
    bpy.ops.object.camera_add(location=(0.0, 0.0, 6.0), rotation=(0.0, 0.0, 0.0))
    camera = bpy.context.active_object
    camera.data.type = "ORTHO"
    # Zoom past the mesh bounds so the visible letters nearly touch the icon edge.
    camera.data.ortho_scale = max(width, height) / 1.12
    bpy.context.scene.camera = camera

    area_light("Key", (-1.8, -1.4, 3.4), 90, 3.6, (1.0, 0.98, 0.95), letters)
    area_light("Rim", (2.4, 0.2, 1.8), 70, 1.8, (0.62, 0.94, 1.0), letters)
    return letters


THEMES = {
    "default": {
        "filename": "AppIcon.png",
        "background": (0.010, 0.038, 0.050),
        "face": (0.97, 0.96, 0.93),
        "side": (0.045, 0.13, 0.17),
    },
    "dark": {
        "filename": "AppIcon-dark.png",
        "background": (0.004, 0.012, 0.016),
        "face": (0.96, 0.96, 0.94),
        "side": (0.03, 0.09, 0.12),
    },
    "tinted": {
        "filename": "AppIcon-tinted.png",
        "background": (0.56, 0.56, 0.56),
        "face": (0.96, 0.96, 0.96),
        "side": (0.28, 0.28, 0.28),
    },
}


def main():
    options = parse_args()
    os.makedirs(options["out"], exist_ok=True)
    configure_render(options["size"])
    names = [options["only"]] if options["only"] else list(THEMES)
    for name in names:
        theme = THEMES[name]
        build(theme)
        configure_render(options["size"])
        path = os.path.join(options["out"], theme["filename"])
        bpy.context.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        if name == "default":
            blend_path = os.path.join(os.path.dirname(__file__), "OP-Remote.blend")
            bpy.ops.wm.save_as_mainfile(filepath=blend_path)
        print(f"rendered {path}")


if __name__ == "__main__":
    main()
