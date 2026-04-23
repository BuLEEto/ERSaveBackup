package main

import "core:os"
import "core:unicode/utf16"

// Trimmed subset of ERBossCheckList/save_parser.odin — only the bits we
// need to show a character hint in the save picker. Event-flag / boss-
// progress parsing is out of scope for a backup tool.

BND4_MAGIC        :: [4]u8{'B', 'N', 'D', '4'}
BND4_HEADER_SIZE  :: 0x40
ENTRY_HEADER_SIZE :: 0x20
SLOT_COUNT        :: 10

PROFILE_SUMMARY_OFFSET :: 0x1964
PROFILE_ENTRY_SIZE     :: 0x24C

BND4_Entry :: struct {
	entry_size:  u64,
	data_offset: u32,
	name_offset: u32,
}

Save_File :: struct {
	path:       string,
	raw_data:   []u8,
	entries:    []BND4_Entry,
	file_count: u32,
}

Character_Slot :: struct {
	index:  int,
	active: bool,
	name:   string,
	level:  u32,
}

open_save_file :: proc(path: string, allocator := context.allocator) -> (Save_File, bool) {
	save: Save_File
	save.path = path

	raw, read_err := os.read_entire_file(path, allocator)
	if read_err != nil do return save, false
	save.raw_data = raw

	if len(raw) < BND4_HEADER_SIZE do return save, false

	magic := (^[4]u8)(&raw[0])^
	if magic != BND4_MAGIC do return save, false

	save.file_count = read_u32_le(raw, 0x0C)

	save.entries = make([]BND4_Entry, save.file_count, allocator)
	for i in 0 ..< save.file_count {
		off := BND4_HEADER_SIZE + int(i) * ENTRY_HEADER_SIZE
		save.entries[i] = BND4_Entry {
			entry_size  = read_u64_le(raw, off + 0x08),
			data_offset = read_u32_le(raw, off + 0x10),
			name_offset = read_u32_le(raw, off + 0x14),
		}
	}

	return save, true
}

close_save_file :: proc(save: ^Save_File, allocator := context.allocator) {
	if save.raw_data != nil {
		delete(save.raw_data, allocator)
		save.raw_data = nil
	}
	if save.entries != nil {
		delete(save.entries, allocator)
		save.entries = nil
	}
}

get_character_slots :: proc(save: ^Save_File, allocator := context.allocator) -> []Character_Slot {
	if int(save.file_count) < 11 do return nil

	ud10_entry := save.entries[10]
	ud10_start := int(ud10_entry.data_offset)
	ud10_size  := int(ud10_entry.entry_size)

	if ud10_start + ud10_size > len(save.raw_data) do return nil

	ud10 := save.raw_data[ud10_start:]
	ps_off := PROFILE_SUMMARY_OFFSET

	if ps_off + 10 + SLOT_COUNT * PROFILE_ENTRY_SIZE > ud10_size do return nil

	slots := make([]Character_Slot, SLOT_COUNT, allocator)

	for i in 0 ..< SLOT_COUNT {
		slots[i].index = i
		slots[i].active = ud10[ps_off + i] != 0
	}

	for i in 0 ..< SLOT_COUNT {
		if !slots[i].active do continue
		entry_off := ps_off + 10 + i * PROFILE_ENTRY_SIZE
		slots[i].name = read_utf16le_name(ud10[entry_off:entry_off + 32], allocator)
		slots[i].level = read_u32_le(ud10, entry_off + 0x22)
	}

	return slots
}

read_u32_le :: proc(data: []u8, offset: int) -> u32 {
	if offset + 4 > len(data) do return 0
	return u32(data[offset]) |
	       (u32(data[offset + 1]) << 8) |
	       (u32(data[offset + 2]) << 16) |
	       (u32(data[offset + 3]) << 24)
}

read_u64_le :: proc(data: []u8, offset: int) -> u64 {
	if offset + 8 > len(data) do return 0
	return u64(data[offset]) |
	       (u64(data[offset + 1]) << 8) |
	       (u64(data[offset + 2]) << 16) |
	       (u64(data[offset + 3]) << 24) |
	       (u64(data[offset + 4]) << 32) |
	       (u64(data[offset + 5]) << 40) |
	       (u64(data[offset + 6]) << 48) |
	       (u64(data[offset + 7]) << 56)
}

read_utf16le_name :: proc(data: []u8, allocator := context.allocator) -> string {
	if len(data) < 2 do return ""

	char_count := len(data) / 2
	chars := make([]u16, char_count, context.temp_allocator)
	for i in 0 ..< char_count {
		chars[i] = u16(data[i * 2]) | (u16(data[i * 2 + 1]) << 8)
		if chars[i] == 0 {
			chars = chars[:i]
			break
		}
	}

	if len(chars) == 0 do return ""

	runes := make([]rune, len(chars), context.temp_allocator)
	n := utf16.decode(runes, chars)
	if n <= 0 do return ""

	buf := make([dynamic]u8, 0, n * 4, allocator)
	for r in runes[:n] {
		if r < 0x80 {
			append(&buf, u8(r))
		} else if r < 0x800 {
			append(&buf, u8(0xC0 | (r >> 6)))
			append(&buf, u8(0x80 | (r & 0x3F)))
		} else if r < 0x10000 {
			append(&buf, u8(0xE0 | (r >> 12)))
			append(&buf, u8(0x80 | ((r >> 6) & 0x3F)))
			append(&buf, u8(0x80 | (r & 0x3F)))
		} else {
			append(&buf, u8(0xF0 | (r >> 18)))
			append(&buf, u8(0x80 | ((r >> 12) & 0x3F)))
			append(&buf, u8(0x80 | ((r >> 6) & 0x3F)))
			append(&buf, u8(0x80 | (r & 0x3F)))
		}
	}
	return string(buf[:])
}
