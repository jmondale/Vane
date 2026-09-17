# Vane app icon

Source artwork for the Vane app icon: a weather vane arrow on the diagonal,
over the cardinal cross it turns on, on the app's own clear-sky gradient.

The colours are the `.clear` / `.mainlyClear` pair from
`WeatherCondition.accentColors(isDaytime:)` in `Vane/ConditionStyle.swift`, so
the icon reads as the same family as the app window and the widget card.

## Files

| File | Purpose |
|---|---|
| `1-cardinal-cross.svg` | Back foreground layer — the axis-aligned cross |
| `2-vane-arrow.svg` | Front foreground layer — the vane arrow |
| `render-preview.swift` | Renders the flattened previews below |
| `preview.png`, `preview-128.png`, `preview-32.png` | Flattened approximations |
| `compiled-icon.png` | Reference render only — **not** a source image |

`compiled-icon.png` was extracted from a compiled `.icns` to check how the
system actually renders the design. It is 256×256 and already has the squircle
mask, drop shadow, and specular highlight baked in, so feeding it back into an
asset catalog double-applies all of that. The two SVGs are the only sources.

This folder is deliberately outside `Vane/` and `WeatherWidget/`. Those are
file-system-synchronized groups, so anything placed in them is added to a
build target automatically — which is not what you want for source artwork.

## Previews

`render-preview.swift` is only an approximation for judging the drawing. It
fakes the background gradient, the cross's opacity, and the rounded-rect mask;
the real icon is composited by the system with Liquid Glass effects that it
can't reproduce. Regenerate with:

```sh
cd Design/AppIcon && swift render-preview.swift
```

## Assembling in Icon Composer

The layers are exported per Apple's guidance: full-bleed 1024×1024, vector,
fully opaque, no background, and no baked-in gradients, shadows, or blurs —
the system supplies those dynamically.

The assembled icon already exists at `Vane/AppIcon.icon`. These steps are the
record of how it was built; follow them again only if rebuilding from scratch.

1. Open Icon Composer (in Xcode, or from the Apple Developer site) and create
   a new icon named `AppIcon`. The filename is the icon's name: `AppIcon.icon`
   is what makes the build setting value `AppIcon`.
2. Drag in `1-cardinal-cross.svg`, then `2-vane-arrow.svg`. Layers render back
   to front, so the cross must sit below the arrow.
3. Select the **icon's own root row** in the sidebar — the one named `AppIcon`,
   above the group and layers — and set the background fill to **Gradient**,
   top to bottom:
   - From `#0088FF`
   - To `#00C0E8`

   Selecting a *layer* here instead applies the gradient to the artwork. With
   these colours that paints the arrow the same blue as the background and it
   vanishes. If a layer's fill is wrong, set its Fill back to **Automatic** so
   it uses the white from the SVG.
4. Select the cross layer and set its **Opacity** to about **40%**. Leave the
   arrow fully opaque. This is the whole source of depth in the design, so it
   is worth previewing against the dark and clear variants before settling.
5. Leave Specular on **Automatic** and leave Blur, Refraction, Translucency,
   and Shadow at their defaults to start.
6. Check the **mono** appearance. Both layers are white, so mono collapses
   them into one flat shape; if the cross disappears, raise its opacity for
   that variant specifically rather than changing the default.

## Wiring it into the build

Two things are required, and the icon stays invisible if either is missing.

1. **The `.icon` must live inside the `Vane/` folder.** That folder is a
   file-system-synchronized group, so anything in it is added to the Vane
   target automatically. A `.icon` beside the `.xcodeproj` at the repo root is
   invisible to the build.

   Do **not** drag the `.icon` onto `Assets.xcassets`. Xcode treats the bundle
   as a folder of loose assets and shreds it into an `icon.dataset` plus
   imagesets, which compiles but sets no icon.

2. **Set the target's App Icon.** Select the **Vane** target → **General** →
   **App Icon** → choose `AppIcon`. Equivalently, Build Settings → search
   "App Icon Name" → set `ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon`.

   This is what passes `--app-icon AppIcon` to `actool`. Without it `actool`
   still compiles the artwork into `Assets.car`, but emits no `AppIcon.icns`
   and no `CFBundleIconName`, so nothing shows an icon.

Don't also create an `AppIcon.appiconset` in `Assets.xcassets`. Two assets
sharing the name collide, and an Icon Composer file supersedes an asset-catalog
icon anyway — pick one mechanism. For a macOS 27 target the `.icon` is the one
you want, since it's what carries the layered Liquid Glass treatment.

To verify, build and check:

```sh
plutil -p "$(ls -d ~/Library/Developer/Xcode/DerivedData/Vane-*/Build/Products/Debug/Vane.app)/Contents/Info.plist" | grep -i icon
```

Both `CFBundleIconFile` and `CFBundleIconName` should come back as `AppIcon`.

## Editing the SVGs by hand

**Quit Icon Composer first.** It keeps its own copy of the layer artwork in
memory and rewrites everything under `AppIcon.icon/Assets/` when you save, so
a hand-edit to an SVG is silently reverted by the next ⌘S. This has already
happened once: a cross-thickness change was reverted from 90u back to 64u.

Patch `Design/AppIcon/1-cardinal-cross.svg` (or `2-vane-arrow.svg`), copy it
into `Vane/AppIcon.icon/Assets/`, and keep the two in sync. Verify with:

```sh
diff Design/AppIcon/1-cardinal-cross.svg Vane/AppIcon.icon/Assets/1-cardinal-cross.svg
```

Geometry (thickness, length, shape) lives in the SVGs. Opacity, fill, and the
background gradient live in `icon.json` and are safe to set in Icon Composer.

## Current settings

| Setting | Value | Where |
|---|---|---|
| Background | `#0088FF` → `#00C0E8`, linear | `icon.json` `fill` |
| Cross opacity | 40% | `icon.json` layer |
| Cross thickness | 90u, arms 564u, `rx` 27 | `1-cardinal-cross.svg` |
| Arrow shaft | 76u | `2-vane-arrow.svg` |

Thickness was chosen by compiling 64/90/120/150 through `actool` and comparing
at real sizes — see `thickness-comparison.png`. Opacity likewise, in
`opacity-comparison.png`. Regenerate either with `compare-variants.swift`.

## Notes and known limits

- **32px is weak.** The arrow silhouette survives, but the cross fades out and
  the arrowhead's barbs merge. That is near the practical limit for a design
  with two elements; if the Finder-list rendering matters more than the Dock
  rendering, the fix is to drop the cross and enlarge the arrow.
- **Geometry is duplicated.** `render-preview.swift` restates the coordinates
  from the two SVGs. If you change a shape, change it in both or the preview
  will quietly stop matching the artwork.
- **Corner rounding is a stroke trick.** Each path is stroked with its own
  fill colour and a round line join, which rounds the corners and expands the
  shape by 10 units on all sides. If you re-draw these in a vector editor,
  convert the strokes to outlines first.
- **The widget needs no icon of its own.** Widgets show the host app's icon, so
  `WeatherWidget/Assets.xcassets` holds only its colour sets. The template
  `AppIcon.appiconset` that shipped with the widget target has been removed.
