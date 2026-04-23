package main

import "gui:skald"

make_theme :: proc() -> skald.Theme {
	t := skald.theme_dark()
	t.color.primary    = skald.rgb(0xD4AF37) // Erdtree gold
	t.color.on_primary = skald.rgb(0x0A0A0A)
	t.color.bg         = skald.rgb(0x151210)
	t.color.surface    = skald.rgb(0x1F1B17)
	t.color.elevated   = skald.rgb(0x2A241E)
	t.color.border     = skald.rgb(0x3A332B)
	t.color.fg         = skald.rgb(0xF2E8C9)
	t.color.fg_muted   = skald.rgb(0x9C8F72)
	return t
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "ER Save Backup",
		size   = {900, 680},
		theme  = make_theme(),
		init   = init,
		update = update,
		view   = view,
	})
}
