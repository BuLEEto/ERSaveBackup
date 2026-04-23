package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	// Bootstrap the tick loop. view runs pure w.r.t. state, but queuing
	// a Msg is the same thing any widget does on click.
	if !s.ticking {
		skald.send(ctx, Tick{})
	}

	return skald.col(
		header_bar(ctx, s),
		skald.spacer(th.spacing.sm),

		skald.flex(1, skald.row(
			profile_list(ctx, s),
			skald.spacer(th.spacing.md),
			skald.flex(1, profile_detail(ctx, s)),
			cross_align = .Stretch,
		)),

		skald.spacer(th.spacing.md),
		log_panel(ctx, s),

		new_profile_dialog(ctx, s),
		delete_confirm_dialog(ctx, s),
		restore_picker_dialog(ctx, s),
		restore_confirm_dialog(ctx, s),

		padding     = th.spacing.lg,
		cross_align = .Stretch,
	)
}

header_bar :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	er_label := "Elden Ring: not running"
	er_color := th.color.fg_muted
	if s.er_running {
		er_label = "Elden Ring: running"
		er_color = th.color.success
	}

	return skald.row(
		skald.text("ER Save Backup", th.color.primary, th.font.size_xl),
		skald.spacer(th.spacing.lg),
		skald.text(er_label, er_color, th.font.size_md),
		skald.flex(1, skald.spacer(0)),
		skald.button(ctx, "Rescan saves", Rescan_Saves{},
			color = th.color.surface, fg = th.color.fg),
		skald.spacer(th.spacing.sm),
		skald.button(ctx, "+ New Profile", New_Profile_Open{}),
		cross_align = .Center,
	)
}

profile_list :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	if len(s.profiles) == 0 {
		return skald.col(
			skald.text("No profiles yet.",
				th.color.fg_muted, th.font.size_md),
			skald.spacer(th.spacing.sm),
			skald.text("Click \"+ New Profile\" to add one.",
				th.color.fg_muted, th.font.size_sm),
			width   = 240,
			padding = th.spacing.md,
			bg      = th.color.surface,
			radius  = th.radius.md,
		)
	}

	rows := make([dynamic]skald.View, 0, len(s.profiles),
		context.temp_allocator)
	for p in s.profiles {
		selected := p.id == s.selected_id
		bg := th.color.surface
		if selected { bg = th.color.elevated }

		label := p.name
		if len(label) == 0 { label = "(unnamed)" }

		// Leading indicator: green check when auto-backup is actively
		// armed, a space-sized placeholder otherwise so button x-positions
		// stay aligned across rows.
		indicator: skald.View
		if p.enabled && p.interval_minutes > 0 {
			indicator = skald.text("✓", th.color.success, th.font.size_md)
		} else {
			indicator = skald.text(" ", th.color.fg_muted, th.font.size_md)
		}

		append(&rows, skald.row(
			indicator,
			skald.spacer(th.spacing.xs),
			skald.flex(1, skald.button(ctx, label, Select_Profile(p.id),
				id     = skald.hash_id(fmt.tprintf("prof-row:%d", p.id)),
				color  = bg,
				fg     = th.color.fg,
				text_align = .Start,
			)),
			cross_align = .Center,
		))
	}

	return skald.col(
		..rows[:],
		width   = 240,
		spacing = th.spacing.xs,
		padding = th.spacing.sm,
		bg      = th.color.surface,
		radius  = th.radius.md,
	)
}

profile_detail :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	p: ^Profile
	for &pp in s.profiles {
		if pp.id == s.selected_id { p = &pp; break }
	}

	if p == nil {
		return skald.col(
			skald.text("Select a profile from the left.",
				th.color.fg_muted, th.font.size_md),
			padding = th.spacing.xl,
			bg      = th.color.surface,
			radius  = th.radius.md,
		)
	}

	last_label := "never"
	if p.last_backup_unix > 0 {
		last_label = format_local_time(p.last_backup_unix, s.tz)
	}

	interval_str := "manual only"
	if p.interval_minutes > 0 {
		interval_str = format_interval(p.interval_minutes)
	}

	toggle_label := "Enable auto-backup"
	toggle_msg   := Toggle_Enabled(p.id)
	if p.enabled { toggle_label = "Disable auto-backup" }

	return skald.col(
		skald.text(p.name, th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.lg),

		field_row_path(ctx, "Source file", p.source_file, skald.hash_id(fmt.tprintf("src-tip:%d", p.id))),
		skald.spacer(th.spacing.sm),
		field_row_path(ctx, "Backup dir", p.backup_dir, skald.hash_id(fmt.tprintf("dst-tip:%d", p.id))),
		skald.spacer(th.spacing.sm),
		field_row(ctx, "Interval", interval_str),
		skald.spacer(th.spacing.sm),
		field_row(ctx, "Max backups", fmt.tprintf("%d", p.max_backups)),
		skald.spacer(th.spacing.sm),
		field_row(ctx, "Last backup", last_label),
		skald.spacer(th.spacing.lg),

		skald.row(
			skald.button(ctx, "Back Up Now", Manual_Backup(p.id),
				id = skald.hash_id(fmt.tprintf("backup-now:%d", p.id))),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, "Restore…", Restore_Open(p.id),
				id    = skald.hash_id(fmt.tprintf("restore:%d", p.id)),
				color = th.color.elevated, fg = th.color.fg),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, toggle_label, toggle_msg,
				id    = skald.hash_id(fmt.tprintf("toggle:%d", p.id)),
				color = th.color.elevated, fg = th.color.fg),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, "Edit", Edit_Profile_Open(p.id),
				id    = skald.hash_id(fmt.tprintf("edit:%d", p.id)),
				color = th.color.elevated, fg = th.color.fg),
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Delete", Delete_Profile_Ask(p.id),
				id    = skald.hash_id(fmt.tprintf("delete:%d", p.id)),
				color = th.color.danger),
			cross_align = .Center,
		),

		padding     = th.spacing.xl,
		bg          = th.color.surface,
		radius      = th.radius.md,
		spacing     = 0,
		cross_align = .Stretch,
	)
}

format_interval :: proc(minutes: int, allocator := context.temp_allocator) -> string {
	if minutes == 1 do return strings.clone("every minute", allocator)
	return fmt.aprintf("every %d minutes", minutes, allocator = allocator)
}

field_row :: proc(ctx: ^skald.Ctx(Msg), label, value: string) -> skald.View {
	th := ctx.theme
	shown := value
	if len(shown) == 0 { shown = "—" }
	return skald.row(
		skald.col(
			skald.text(label, th.color.fg_muted, th.font.size_sm),
			width = 120,
		),
		skald.flex(1, skald.text(shown, th.color.fg, th.font.size_md,
			max_width = 540)),
		cross_align = .Start,
	)
}

// field_row_path is field_row for long filesystem paths: it trims the
// value to a reasonable width and wraps the trimmed label in a tooltip
// that shows the full path on hover.
field_row_path :: proc(ctx: ^skald.Ctx(Msg), label, value: string, tip_id: skald.Widget_ID) -> skald.View {
	th := ctx.theme
	shown := value
	if len(shown) == 0 { shown = "—" }

	display := shown
	MAX :: 56
	if len(display) > MAX {
		// Keep the tail — the filename / last folder is the meaningful
		// part; the long ~/.steam/steamapps/compatdata/... prefix is
		// repetitive and already visible via hover tooltip.
		display = fmt.tprintf("…%s", display[len(display) - (MAX - 1):])
	}

	value_view := skald.text(display, th.color.fg, th.font.size_md)
	if len(value) > MAX {
		value_view = skald.tooltip(ctx, value_view, value, id = tip_id)
	}

	return skald.row(
		skald.col(
			skald.text(label, th.color.fg_muted, th.font.size_sm),
			width = 120,
		),
		skald.flex(1, value_view),
		cross_align = .Start,
	)
}

on_delete_dismiss :: proc() -> Msg { return Delete_Profile_Cancel{} }
on_restore_dismiss :: proc() -> Msg { return Restore_Close{} }
on_restore_confirm_dismiss :: proc() -> Msg { return Restore_Cancel{} }

restore_picker_dialog :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	name := ""
	for p in s.profiles {
		if p.id == s.restoring_id { name = p.name; break }
	}
	if len(name) == 0 { name = "(unnamed)" }

	rows := make([dynamic]skald.View, 0, len(s.restore_entries) + 2,
		context.temp_allocator)

	if s.er_running {
		append(&rows, skald.text(
			"Elden Ring is running — close the game before restoring.",
			th.color.danger, th.font.size_sm))
		append(&rows, skald.spacer(th.spacing.sm))
	}

	if len(s.restore_entries) == 0 {
		append(&rows, skald.text(
			"No backups found for this profile yet.",
			th.color.fg_muted, th.font.size_md))
	} else {
		for e, i in s.restore_entries {
			label: string
			if e.stamp_unix > 0 {
				label = format_local_time(e.stamp_unix, s.tz)
			} else {
				label = filepath.base(e.path)
			}
			tag_view: skald.View
			if e.is_prerestore {
				tag_view = skald.text(" (pre-restore snapshot)",
					th.color.fg_muted, th.font.size_sm)
			} else {
				tag_view = skald.spacer(0)
			}

			row_view := skald.row(
				skald.text(label, th.color.fg, th.font.size_md),
				tag_view,
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Restore",
					Restore_Ask{id = s.restoring_id, path = e.path},
					id       = skald.hash_id(fmt.tprintf("restore-row:%d", i)),
					disabled = s.er_running,
					color    = th.color.primary,
					fg       = th.color.on_primary),
				skald.spacer(th.spacing.lg),
				cross_align = .Center,
			)
			append(&rows, row_view)
			if i < len(s.restore_entries) - 1 {
				append(&rows, skald.spacer(th.spacing.sm))
			}
		}
	}

	// Stretch each row to fill the scroll viewport width (minus scrollbar
	// and breathing room) so flex(1, spacer(0)) can push the Restore
	// button clear of the scrollbar track.
	list_view := skald.col(..rows[:],
		spacing     = 0,
		width       = 500,
		cross_align = .Stretch,
	)

	content := skald.col(
		skald.text(fmt.tprintf("Restore — %s", name), th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.text("Newest first. A pre-restore snapshot is taken automatically before overwriting the live save.",
			th.color.fg_muted, th.font.size_sm, max_width = 520),
		skald.spacer(th.spacing.md),

		skald.scroll(ctx, {540, 320}, list_view,
			id = skald.hash_id("restore-scroll")),

		skald.spacer(th.spacing.lg),
		skald.row(
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Close", Restore_Close{},
				color = th.color.surface, fg = th.color.fg),
			cross_align = .Center,
		),
	)

	return skald.dialog(ctx,
		open       = s.restoring_id != 0,
		on_dismiss = on_restore_dismiss,
		content    = content,
		max_width  = 600,
	)
}

restore_confirm_dialog :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	open := s.restoring_id != 0 && len(s.restore_confirm_path) > 0

	label := ""
	if open {
		label = filepath.base(s.restore_confirm_path)
	}

	body := fmt.tprintf(
		"Overwrite the live save with %q? A pre-restore snapshot of the current save will be taken first and kept for one week.",
		label,
	)

	content := skald.col(
		skald.text("Restore this save?", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.text(body, th.color.fg_muted, th.font.size_md, max_width = 440),
		skald.spacer(th.spacing.lg),
		skald.row(
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Cancel", Restore_Cancel{},
				color = th.color.surface, fg = th.color.fg),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, "Restore", Restore_Confirm{},
				color = th.color.primary, fg = th.color.on_primary),
			cross_align = .Center,
		),
	)

	return skald.dialog(ctx,
		open       = open,
		on_dismiss = on_restore_confirm_dismiss,
		content    = content,
		max_width  = 480,
	)
}

delete_confirm_dialog :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	name := ""
	for p in s.profiles {
		if p.id == s.deleting_id { name = p.name; break }
	}
	if len(name) == 0 { name = "(unnamed)" }

	body := fmt.tprintf(
		"Delete profile %q? The profile will be removed from ER Save Backup. Existing backup files on disk are left alone.",
		name,
	)

	content := skald.col(
		skald.text("Delete profile?", th.color.fg, th.font.size_lg),
		skald.spacer(th.spacing.sm),
		skald.text(body, th.color.fg_muted, th.font.size_md, max_width = 420),
		skald.spacer(th.spacing.lg),
		skald.row(
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Cancel", Delete_Profile_Cancel{},
				color = th.color.surface, fg = th.color.fg),
			skald.spacer(th.spacing.sm),
			skald.button(ctx, "Delete", Delete_Profile(s.deleting_id),
				color = th.color.danger),
			cross_align = .Center,
		),
	)

	return skald.dialog(ctx,
		open       = s.deleting_id != 0,
		on_dismiss = on_delete_dismiss,
		content    = content,
		max_width  = 460,
	)
}

log_panel :: proc(ctx: ^skald.Ctx(Msg), s: State) -> skald.View {
	th := ctx.theme

	lines := make([dynamic]skald.View, 0, len(s.log_lines) + 1,
		context.temp_allocator)
	append(&lines,
		skald.text("Activity", th.color.fg_muted, th.font.size_sm))
	if len(s.log_lines) == 0 {
		append(&lines,
			skald.text("(no activity yet)",
				th.color.fg_muted, th.font.size_sm))
	} else {
		for i := len(s.log_lines) - 1; i >= 0; i -= 1 {
			append(&lines,
				skald.text(s.log_lines[i],
					th.color.fg, th.font.size_sm))
		}
	}

	return skald.col(
		..lines[:],
		spacing = 2,
		padding = th.spacing.sm,
		bg      = th.color.surface,
		radius  = th.radius.md,
	)
}

