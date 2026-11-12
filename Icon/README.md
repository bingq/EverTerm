# App icon

- `AppIcon-source.png`: the original square artwork (full bleed, no rounded corners).
- `AppIcon-1024.png`: master on Apple's macOS grid (1024 canvas, 824 rounded square, soft shadow, transparent margin).
- `AppIcon.iconset/`: the 10 sizes macOS uses (16 to 512, each at 1x and 2x).
- `AppIcon.appiconset/`: the same images with `Contents.json`, for an Xcode asset catalog.
- `make_icon.py`: rebuilds everything from the source (`python3 make_icon.py AppIcon-source.png .`, needs Pillow).

Build the `.icns` on a Mac with Apple's tool:

```
iconutil -c icns Icon/AppIcon.iconset -o Icon/AppIcon.icns
```

While EverTerm runs with `swift run` there is no `.app` bundle, so the Dock icon is set at launch from
`Sources/EverTerm/Resources/AppIcon.png` (512 px copy of the master). A real `.app` (Xcode project, needed
for the App Store) uses `AppIcon.appiconset` instead.
