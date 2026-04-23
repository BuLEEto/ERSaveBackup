package main

import "core:fmt"
import "core:strings"
import "gui:skald"

on_dialog_cancel :: proc() -> Msg { return New_Profile_Cancel{} }

on_draft_name        :: proc(v: string) -> Msg { return Draft_Name(v)        }
on_draft_backup_dir  :: proc(v: string) -> Msg { return Draft_Backup_Dir(v)  }
on_draft_max_backups :: proc(v: string) -> Msg { return Draft_Max_Backups(v) }
on_draft_interval    :: proc(v: string) -> Msg { return Draft_Interval(v)    }
on_draft_enabled     :: proc(v: bool)   -> Msg { return Draft_Enabled(v)     }
on_draft_custom_path :: proc(v: string) -> Msg { return Draft_Custom_Path(v) }

save_tooltip_text :: proc(ds: Detected_Save, allocator := context.temp_allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	strings.write_string(&b, ds.path)
	if len(ds.slots) == 0 {
		strings.write_string(&b, "\n\n(no active characters)")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\n")
	for sl in ds.slots {
		name := sl.name
		if len(name) == 0 { name = "(unnamed)" }
		strings.write_string(&b, "\n")
		fmt.sbprintf(&b, "Slot %d: %s — Lv %d", sl.slot, name, sl.level)
	}
	return strings.to_string(b)
}

save_option_row :: proc(ctx: ^skald.Ctx(Msg), ds: Detected_Save, idx: int, selected: bool) -> skald.View {
	th := ctx.theme

	glyph := "○"
	bg    := th.color.surface
	if selected {
		glyph = "●"
		bg    = th.color.elevated
	}
	label := fmt.tprintf("%s  %s", glyph, ds.filename)

	btn := skald.button(ctx, label, Draft_Select_Save(idx),
		id         = skald.hash_id(fmt.tprintf("save-row:%d", idx)),
		color      = bg,
		fg         = th.color.fg,
		text_align = .Start,
		width      = 480,
	)

	return skald.tooltip(ctx, btn, save_tooltip_text(ds),
		id = skald.hash_id(fmt.tprintf("save-tip:%d", idx)))
}

picked_hint :: proc(ctx: ^skald.Ctx(Msg), path: string, tip_id: skald.Widget_ID) -> skald.View {
	th := ctx.theme
	if len(path) == 0 do return skald.spacer(0)

	display := path
	MAX :: 48
	if len(display) > MAX {
		display = fmt.tprintf("…%s", display[len(display) - (MAX - 1):])
	}

	label := skald.text(fmt.tprintf("Selected: %s", display),
		th.color.fg_muted, th.font.size_sm)
	if len(path) > MAX {
		label = skald.tooltip(ctx, label, path, id = tip_id)
	}
	return skald.col(
		skald.spacer(th.spacing.xs),
		label,
	)
}

custom_option_row :: proc(ctx: ^skald.Ctx(Msg), selected: bool) -> skald.View {
	th := ctx.theme

	glyph := "○"
	bg    := th.color.surface
	if selected {
		glyph = "●"
		bg    = th.color.elevated
	}
	label := fmt.tprintf("%s  Custom path (Browse…)", glyph)

	return skald.button(ctx, label, Draft_Select_Save(-1),
		id         = skald.hash_id("save-row:custom"),
		color      = bg,
		fg         = th.color.fg,
		text_align = .Start,
		width      = 480,
	)
}

new_profile_dialog :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	editing := s.editing_id != 0
	dialog_title := editing ? "Edit Profile" : "New Profile"
	submit_label := editing ? "Save"         : "Create"

	// Build one tooltip-wrapped row per detected save, plus a trailing
	// "Custom path" row mapped to selected_save = -1.
	use_custom := s.draft.selected_save < 0 ||
	              s.draft.selected_save >= len(s.detected_saves)

	save_rows := make([dynamic]skald.View, 0, len(s.detected_saves) + 1,
		context.temp_allocator)
	for ds, i in s.detected_saves {
		selected := !use_custom && i == s.draft.selected_save
		append(&save_rows, save_option_row(ctx, ds, i, selected))
	}
	append(&save_rows, custom_option_row(ctx, use_custom))

	browse_row: skald.View
	if use_custom {
		browse_row = skald.col(
			skald.spacer(th.spacing.xs),
			skald.row(
				skald.flex(1, skald.text_input(ctx,
					s.draft.custom_path, on_draft_custom_path,
					placeholder = "/path/to/ER0000.sl2",
					id = skald.hash_id("draft:custom_path"))),
				skald.spacer(th.spacing.sm),
				skald.button(ctx, "Browse…", Open_File_Dialog_Browse{},
					color = th.color.surface, fg = th.color.fg),
				cross_align = .Center,
			),
			picked_hint(ctx, s.draft.custom_path, skald.hash_id("draft:custom_path:tip")),
		)
	} else {
		browse_row = skald.spacer(0)
	}

	err_row: skald.View = skald.spacer(0)
	if len(s.draft.error) > 0 {
		err_row = skald.col(
			skald.text(s.draft.error,
				th.color.danger, th.font.size_md),
			skald.spacer(th.spacing.sm),
		)
	}

	content := skald.col(
		skald.text(dialog_title, th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),

		skald.text("Name", th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.text_input(ctx, s.draft.name, on_draft_name,
			placeholder = "Seamless, Randomizer, Base Game…",
			width = 420,
			id = skald.hash_id("draft:name")),
		skald.spacer(th.spacing.md),

		skald.text("Pick a save file", th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.col(..save_rows[:], spacing = th.spacing.xs),
		browse_row,
		skald.spacer(th.spacing.md),

		skald.text("Backup destination", th.color.fg_muted, th.font.size_sm),
		skald.spacer(th.spacing.xs),
		skald.row(
			skald.flex(1, skald.text_input(ctx,
				s.draft.backup_dir, on_draft_backup_dir,
				placeholder = "~/ERBackups/Seamless",
				id = skald.hash_id("draft:backup_dir"))),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, "Pick folder…", Open_File_Dialog_Backup_Dir{},
				color = th.color.surface, fg = th.color.fg),
			cross_align = .Center,
		),
		picked_hint(ctx, s.draft.backup_dir, skald.hash_id("draft:backup_dir:tip")),
		skald.spacer(th.spacing.md),

		skald.row(
			skald.col(
				skald.text("Interval (min, 0 = manual)",
					th.color.fg_muted, th.font.size_sm),
				skald.spacer(th.spacing.xs),
				skald.text_input(ctx,
					fmt.tprintf("%d", s.draft.interval_minutes),
					on_draft_interval,
					width = 100,
					id = skald.hash_id("draft:interval")),
				width = 200,
			),
			skald.spacer(th.spacing.md),
			skald.col(
				skald.text("Max backups",
					th.color.fg_muted, th.font.size_sm),
				skald.spacer(th.spacing.xs),
				skald.text_input(ctx,
					fmt.tprintf("%d", s.draft.max_backups),
					on_draft_max_backups,
					width = 100,
					id = skald.hash_id("draft:max")),
			),
			cross_align = .Start,
		),
		skald.spacer(th.spacing.md),

		skald.checkbox(ctx, s.draft.enabled,
			"Enable auto-backup on create", on_draft_enabled,
			id = skald.hash_id("draft:enabled")),
		skald.spacer(th.spacing.lg),

		err_row,

		skald.row(
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Cancel", New_Profile_Cancel{},
				color = th.color.surface, fg = th.color.fg),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, submit_label, New_Profile_Submit{}),
			cross_align = .Center,
		),
	)

	return skald.dialog(ctx,
		open       = s.creating,
		on_dismiss = on_dialog_cancel,
		content    = content,
		max_width  = 560,
	)
}
