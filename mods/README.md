# Mods

Each change in a customized Dock Notch is a mod: one commit whose message starts with
`Mod:`, and a file here describing it. The file is what lets the change be redone when an
update moves the code under it, so it says what the change is for, what it looks like,
which upstream code it hooks into, and how to tell it still works. See CUSTOMIZING.md.

Upstream Dock Notch keeps only this README here, so your mod files never clash with an
update. The same goes for code in `Sources/DockNotch/Mods/`.
