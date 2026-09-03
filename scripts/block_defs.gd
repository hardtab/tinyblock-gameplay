extends Node

const TILE := 32
const GRAVITY := 0.45
const JUMP := -9.5
const MOVE := 1.8
const WORLD_W := 50
const WORLD_H := 28
const MAX_FLUID_LEVEL := 8
const DROP_SEARCH := 4

const BEVEL_LEFT := 1
const BEVEL_TOP := 2
const BEVEL_RIGHT := 4
const BEVEL_BOTTOM := 8
const BEVEL_ALL := 15

const HOTBAR_SIZE := 6
const GENERATED_PATTERNS: PackedStringArray = [
	"grain", "layers", "veins", "crystals", "organic", "cracks",
	"bubbles", "scales", "cells", "metal", "runes", "stripes",
]
const LEGACY_GENERATED_PALETTES: Dictionary = {
	"gen.block.677ad2b96895": ["#5a3a22", "#8a6038", "#342419", "#b88a55"],
}

var BLOCKS := {
	"air": {"id": 0, "solid": false},
	"grass": {
		"id": 1, "solid": true,
		"side": "#6d7a38", "top": "#89b331", "mid": "#7aa52d", "dark": "#6a8c25",
		"hardness": 6
	},
	"dirt": {
		"id": 2, "solid": true,
		"base": "#915831", "mid": "#83502c", "dark": "#6b4024", "light": "#a3683a",
		"hardness": 10
	},
	"stone": {
		"id": 3, "solid": true,
		"base": "#45454d", "mid": "#3a3a42", "dark": "#2e2e35", "light": "#5a5a64",
		"hardness": 28, "harvest_tier": 1,
	},
	"wood": {
		"id": 4, "solid": true,
		"base": "#6b4423", "ring": "#5a381c", "light": "#8b5a2b", "dark": "#4a2f18",
		"hardness": 14, "flammability": 0.9, "temperature": 0.0
	},
	"water": {
		"id": 5, "solid": false, "fluid": true, "decay": 1, "tick_rate": 7,
		"deep": "#1d4ed8", "base": "#2563eb", "light": "#60a5fa",
		"hardness": 4
	},
	"lava": {
		"id": 6, "solid": false, "fluid": true, "decay": 2, "tick_rate": 39,
		"deep": "#c2410c", "base": "#ea580c", "light": "#fb923c",
		"hardness": 5, "flammability": 0.0, "temperature": 1.0
	},
	"cobblestone": {
		"id": 7, "solid": true,
		"base": "#707070", "mid": "#5a5a5a", "dark": "#484848", "light": "#909090",
		"hardness": 22, "harvest_tier": 1,
	},
	"obsidian": {
		"id": 8, "solid": true,
		"base": "#1a1033", "mid": "#2d1b4e", "dark": "#0d081a", "light": "#4a3070",
		"hardness": 55, "harvest_tier": 4,
	},
	"leaves": {
		"id": 9, "solid": true,
		"base": "#3d8c40", "mid": "#2f7a33", "dark": "#1f5a22", "light": "#5cb85c", "hole": "#2a6b2e",
		"hardness": 4, "movement_speed_multiplier": 0.72, "friction": 0.75, "bounce": 0.08,
		"flammability": 1.0, "temperature": 0.0
	},
	"gravel": {
		"id": 10, "solid": true, "generated": true, "pattern": "grain", "visual_seed": 10010,
		"base": "#77746d", "mid": "#65625c", "dark": "#4f4d48", "light": "#99958b",
		"hardness": 14, "movement_speed_multiplier": 0.78, "friction": 0.68, "bounce": 0.0,
		"falls_when_unsupported": true, "settles_diagonally": true
	},
	"sand": {
		"id": 11, "solid": true, "generated": true, "pattern": "grain", "visual_seed": 11011,
		"base": "#d7b96d", "mid": "#c6a65a", "dark": "#a98743", "light": "#eed28a",
		"hardness": 5, "movement_speed_multiplier": 0.65, "friction": 0.55, "bounce": 0.0,
		"falls_when_unsupported": true, "settles_diagonally": true
	},
	"planks": {
		"id": 12, "solid": true, "generated": true, "pattern": "stripes", "visual_seed": 12012,
		"base": "#a66b32", "mid": "#8d5728", "dark": "#6f421f", "light": "#c98a48",
		"hardness": 12, "movement_speed_multiplier": 1.0, "friction": 0.86, "bounce": 0.03,
		"flammability": 0.82, "temperature": 0.0,
		"falls_when_unsupported": false, "settles_diagonally": false
	},
	"glass": {
		"id": 13, "solid": true,
		"base": "#a8e6f2", "mid": "#6fc8dc", "dark": "#3f9fb8", "light": "#e8fbff",
		"hardness": 8, "movement_speed_multiplier": 1.0, "friction": 0.72, "bounce": 0.02
	},
	"charcoal": {
		"id": 14, "solid": true, "generated": true, "pattern": "cracks", "visual_seed": 14014,
		"base": "#292827", "mid": "#353331", "dark": "#151514", "light": "#55514c",
		"hardness": 6, "movement_speed_multiplier": 0.88, "friction": 0.82, "bounce": 0.01,
		"flammability": 0.65, "temperature": 0.05,
		"falls_when_unsupported": false, "settles_diagonally": false
	},
	"stone_pickaxe": {
		"id": 15, "content_id": "core.item.stone_pickaxe", "solid": false, "fluid": false,
		"item": true, "hardness": 1, "base": "#6b4423", "light": "#90909a", "dark": "#3a3a42",
		"definition": {
			"content_id": "core.item.stone_pickaxe", "kind": "item", "schema_version": "1.0",
			"display": {
				"name": {"en": "Stone Pickaxe"},
				"description": {"en": "A sturdy pickaxe that harvests copper ore and mines 35% faster."},
			},
			"visual": {"shape": "pickaxe", "pattern": "banded", "palette": ["#6b4423", "#90909a", "#d2d2d8"]},
			"category": "mining_tool", "rarity": "common",
			"effects": {
				"mining_speed_multiplier": 1.35, "harvest_tier": 2, "creature_damage": 1,
				"movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0,
			},
			"durability": {"max_uses": 96},
			"requirements": {"ingredient_hardness": 0.75, "generated_ingredient_count": 0},
			"tags": ["item", "mining_tool", "stone", "crafted"],
			"mechanics": ["hotbar_active"],
		},
	},
	"trail_boots": {
		"id": 16, "content_id": "core.item.trail_boots", "solid": false, "fluid": false,
		"item": true, "hardness": 1, "base": "#5b4630", "light": "#73b85c", "dark": "#34291f",
		"definition": {
			"content_id": "core.item.trail_boots", "kind": "item", "schema_version": "1.0",
			"display": {
				"name": {"en": "Trail Boots"},
				"description": {"en": "Move 15% faster and jump 5% higher while selected."},
			},
			"visual": {"shape": "boots", "pattern": "inlaid", "palette": ["#5b4630", "#73b85c", "#b6da75"]},
			"category": "mobility_tool", "rarity": "common",
			"effects": {
				"mining_speed_multiplier": 1.0, "creature_damage": 1,
				"movement_speed_multiplier": 1.15, "jump_power_multiplier": 1.05,
			},
			"durability": {"max_uses": 240, "distance_per_use": 8.0},
			"requirements": {"ingredient_hardness": 0.35, "generated_ingredient_count": 0},
			"tags": ["item", "mobility_tool", "boots", "crafted"],
			"mechanics": ["hotbar_active"],
		},
	},
	"ice": {
		"id": 17, "solid": true, "generated": true, "pattern": "crystals", "visual_seed": 17017,
		"base": "#9edcf2", "mid": "#78c4e2", "dark": "#4f9fc5", "light": "#e8fbff",
		"hardness": 7, "movement_speed_multiplier": 1.08, "friction": 0.08, "bounce": 0.01,
		"flammability": 0.0, "temperature": -0.8,
		"falls_when_unsupported": false, "settles_diagonally": false
	},
	"chest": {
		"id": 18, "content_id": "core.chest", "solid": true, "container": true,
		"base": "#9a5d24", "mid": "#b97832", "dark": "#573315", "light": "#d99a4d",
		"hardness": 12, "movement_speed_multiplier": 1.0, "friction": 0.86, "bounce": 0.02,
		"flammability": 0.82, "temperature": 0.0,
	},
	"palm_planks": {
		"id": 19, "content_id": "core.palm_planks", "solid": true, "generated": true,
		"pattern": "stripes", "visual_seed": 19019,
		"base": "#c88a45", "mid": "#a96b34", "dark": "#774522", "light": "#efbd72",
		"hardness": 11, "movement_speed_multiplier": 1.0, "friction": 0.84, "bounce": 0.03,
		"flammability": 0.86, "temperature": 0.0,
		"definition": {"content_id": "core.palm_planks", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Palm Planks"}, "description": {"en": "Light boards cut from fibrous palm trunks."}}, "tags": ["wood", "planks", "crafted", "tropical"]},
	},
	"pine_planks": {
		"id": 20, "content_id": "core.pine_planks", "solid": true, "generated": true,
		"pattern": "layers", "visual_seed": 20020,
		"base": "#93613c", "mid": "#74472d", "dark": "#4d2d20", "light": "#c38a58",
		"hardness": 14, "movement_speed_multiplier": 1.0, "friction": 0.88, "bounce": 0.02,
		"flammability": 0.78, "temperature": 0.0,
		"definition": {"content_id": "core.pine_planks", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Pine Planks"}, "description": {"en": "Dense resinous boards suited to sturdy construction."}}, "tags": ["wood", "planks", "crafted", "cold"]},
	},
	"weeping_planks": {
		"id": 21, "content_id": "core.weeping_planks", "solid": true, "generated": true,
		"pattern": "veins", "visual_seed": 21021,
		"base": "#756356", "mid": "#635146", "dark": "#41372f", "light": "#a18b78",
		"hardness": 12, "movement_speed_multiplier": 1.0, "friction": 0.85, "bounce": 0.04,
		"flammability": 0.8, "temperature": 0.0,
		"definition": {"content_id": "core.weeping_planks", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Weeping Planks"}, "description": {"en": "Muted boards with long flowing grain."}}, "tags": ["wood", "planks", "crafted", "wetland"]},
	},
	"stone_bricks": {
		"id": 22, "content_id": "core.stone_bricks", "solid": true, "generated": true,
		"pattern": "layers", "visual_seed": 22022,
		"base": "#666872", "mid": "#555761", "dark": "#3d3f47", "light": "#858893",
		"hardness": 32, "movement_speed_multiplier": 1.0, "friction": 0.92, "bounce": 0.01,
		"definition": {"content_id": "core.stone_bricks", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Stone Bricks"}, "description": {"en": "Cut masonry for durable walls and platforms."}}, "tags": ["stone", "brick", "crafted"]},
	},
	"sandstone": {
		"id": 23, "content_id": "core.sandstone", "solid": true, "generated": true,
		"pattern": "layers", "visual_seed": 23023,
		"base": "#d4b46d", "mid": "#bd984f", "dark": "#92703b", "light": "#edd28e",
		"hardness": 18, "movement_speed_multiplier": 1.0, "friction": 0.82, "bounce": 0.02,
		"definition": {"content_id": "core.sandstone", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Sandstone"}, "description": {"en": "Compressed sand reinforced with stone."}}, "tags": ["stone", "sand", "crafted"]},
	},
	"woven_thatch": {
		"id": 24, "content_id": "core.woven_thatch", "solid": true, "generated": true,
		"pattern": "cells", "visual_seed": 24024,
		"base": "#7c9b3f", "mid": "#627d30", "dark": "#40551f", "light": "#a8c95a",
		"hardness": 7, "movement_speed_multiplier": 0.94, "friction": 0.8, "bounce": 0.06,
		"flammability": 0.96, "temperature": 0.0,
		"definition": {"content_id": "core.woven_thatch", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Woven Thatch"}, "description": {"en": "Palm fronds woven into a light building block."}}, "tags": ["organic", "woven", "crafted", "flammable"]},
	},
	"packed_ice": {
		"id": 25, "content_id": "core.packed_ice", "solid": true, "generated": true,
		"pattern": "crystals", "visual_seed": 25025,
		"base": "#6bb8d9", "mid": "#4d9fc5", "dark": "#317ca4", "light": "#c7f1ff",
		"hardness": 14, "movement_speed_multiplier": 1.16, "friction": 0.04, "bounce": 0.02,
		"temperature": -0.9,
		"definition": {"content_id": "core.packed_ice", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Packed Ice"}, "description": {"en": "Dense polished ice that stays cold and very slippery."}}, "tags": ["ice", "cold", "crafted"]},
	},
	"polished_obsidian": {
		"id": 26, "content_id": "core.polished_obsidian", "solid": true, "generated": true,
		"pattern": "veins", "visual_seed": 26026,
		"base": "#24123f", "mid": "#3b2061", "dark": "#10081f", "light": "#7650a0",
		"hardness": 64, "movement_speed_multiplier": 1.0, "friction": 0.9, "bounce": 0.01,
		"definition": {"content_id": "core.polished_obsidian", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Polished Obsidian"}, "description": {"en": "Volcanic glass cut into a dark reflective building block."}}, "tags": ["stone", "obsidian", "crafted"]},
	},
	"lantern": {
		"id": 27, "content_id": "core.lantern", "solid": true, "generated": true,
		"pattern": "runes", "visual_seed": 27027,
		"base": "#765525", "mid": "#c49135", "dark": "#352616", "light": "#fff1a3",
		"hardness": 9, "movement_speed_multiplier": 1.0, "friction": 0.82, "bounce": 0.02,
		"flammability": 0.0, "temperature": 0.15,
		"definition": {"content_id": "core.lantern", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Lantern"}, "description": {"en": "A charcoal lamp enclosed in glass that lights nearby blocks."}}, "lighting": {"emission": 1.0, "color": "#ffd76a"}, "tags": ["crafted", "light_source", "glowing"]},
	},
	"wooden_pickaxe": {
		"id": 28, "content_id": "core.item.wooden_pickaxe", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#6b4423", "light": "#c98a48", "dark": "#4a2f18",
		"definition": {"content_id": "core.item.wooden_pickaxe", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Wooden Pickaxe"}, "description": {"en": "A starter pickaxe that harvests stone and mines 15% faster."}}, "visual": {"shape": "pickaxe", "pattern": "banded", "palette": ["#6b4423", "#c98a48", "#efbd72"]}, "category": "mining_tool", "rarity": "common", "effects": {"mining_speed_multiplier": 1.15, "harvest_tier": 1, "creature_damage": 1, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 48}, "tags": ["item", "mining_tool", "wood", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"stone_axe": {
		"id": 29, "content_id": "core.item.stone_axe", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#704625", "light": "#a2a2aa", "dark": "#3a3a42",
		"definition": {"content_id": "core.item.stone_axe", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Stone Axe"}, "description": {"en": "A versatile hand tool that mines faster and deals 2 damage."}}, "visual": {"shape": "hammer", "pattern": "banded", "palette": ["#704625", "#92949c", "#d4d5da"]}, "category": "hybrid", "rarity": "common", "effects": {"mining_speed_multiplier": 1.25, "creature_damage": 2, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 112}, "tags": ["item", "axe", "tool", "stone", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"stone_sword": {
		"id": 30, "content_id": "core.item.stone_sword", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#6b4423", "light": "#b5b6bd", "dark": "#3d3e45",
		"definition": {"content_id": "core.item.stone_sword", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Stone Sword"}, "description": {"en": "A balanced stone blade that deals 3 damage."}}, "visual": {"shape": "blade", "pattern": "inlaid", "palette": ["#6b4423", "#a8aab2", "#e1e2e5"]}, "category": "weapon", "rarity": "common", "effects": {"mining_speed_multiplier": 1.0, "creature_damage": 3, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 128}, "tags": ["item", "weapon", "blade", "stone", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"obsidian_pickaxe": {
		"id": 31, "content_id": "core.item.obsidian_pickaxe", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#6b4423", "light": "#75509b", "dark": "#160b29",
		"definition": {"content_id": "core.item.obsidian_pickaxe", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Obsidian Pickaxe"}, "description": {"en": "A late-game pickaxe that harvests the rarest crystals and mines 90% faster."}}, "visual": {"shape": "pickaxe", "pattern": "glowing", "palette": ["#6b4423", "#65428c", "#b486df"]}, "category": "mining_tool", "rarity": "rare", "effects": {"mining_speed_multiplier": 1.9, "harvest_tier": 5, "creature_damage": 2, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 280}, "tags": ["item", "mining_tool", "obsidian", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"palm_sandals": {
		"id": 32, "content_id": "core.item.palm_sandals", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#8a5a2e", "light": "#9fc453", "dark": "#4d371f",
		"definition": {"content_id": "core.item.palm_sandals", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Palm Sandals"}, "description": {"en": "Light woven footwear that improves speed by 22% and jumping by 10%."}}, "visual": {"shape": "boots", "pattern": "banded", "palette": ["#8a5a2e", "#9fc453", "#d9e88c"]}, "category": "mobility_tool", "rarity": "common", "effects": {"mining_speed_multiplier": 1.0, "creature_damage": 1, "movement_speed_multiplier": 1.22, "jump_power_multiplier": 1.1}, "durability": {"max_uses": 180, "distance_per_use": 7.0}, "tags": ["item", "mobility_tool", "boots", "palm", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"ice_boots": {
		"id": 33, "content_id": "core.item.ice_boots", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#456a78", "light": "#a9e9ff", "dark": "#284651",
		"definition": {"content_id": "core.item.ice_boots", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Ice Boots"}, "description": {"en": "Cold-weather boots that improve speed by 30% and jumping by 8%."}}, "visual": {"shape": "boots", "pattern": "inlaid", "palette": ["#456a78", "#a9e9ff", "#e4f9ff"]}, "category": "mobility_tool", "rarity": "uncommon", "effects": {"mining_speed_multiplier": 1.0, "creature_damage": 1, "movement_speed_multiplier": 1.3, "jump_power_multiplier": 1.08}, "durability": {"max_uses": 240, "distance_per_use": 8.0}, "tags": ["item", "mobility_tool", "boots", "ice", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"amethyst_crystal": {
		"id": 34, "content_id": "core.amethyst_crystal", "solid": true, "generated": true, "pattern": "crystals", "visual_seed": 34034,
		"base": "#6d3fa2", "mid": "#925bd0", "dark": "#38205b", "light": "#e1b8ff", "hardness": 24, "harvest_tier": 3, "movement_speed_multiplier": 1.0, "friction": 0.82, "bounce": 0.06,
		"definition": {"content_id": "core.amethyst_crystal", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Amethyst Crystal"}, "description": {"en": "A luminous violet crystal found in rare grottos."}}, "lighting": {"emission": 0.78, "color": "#c88cff"}, "tags": ["crystal", "gem", "glowing", "underground"]},
	},
	"rose_crystal": {
		"id": 35, "content_id": "core.rose_crystal", "solid": true, "generated": true, "pattern": "crystals", "visual_seed": 35035,
		"base": "#b74483", "mid": "#df68a7", "dark": "#67264e", "light": "#ffc1e5", "hardness": 20, "harvest_tier": 3, "movement_speed_multiplier": 1.0, "friction": 0.8, "bounce": 0.08,
		"definition": {"content_id": "core.rose_crystal", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Rose Crystal"}, "description": {"en": "A warm pink crystal that softly lights nearby stone."}}, "lighting": {"emission": 0.7, "color": "#ff78ba"}, "tags": ["crystal", "gem", "glowing"]},
	},
	"emerald_crystal": {
		"id": 36, "content_id": "core.emerald_crystal", "solid": true, "generated": true, "pattern": "crystals", "visual_seed": 36036,
		"base": "#177a61", "mid": "#28ad83", "dark": "#0b4639", "light": "#85f4c2", "hardness": 30, "harvest_tier": 5, "movement_speed_multiplier": 1.0, "friction": 0.86, "bounce": 0.04,
		"definition": {"content_id": "core.emerald_crystal", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Emerald Crystal"}, "description": {"en": "A rare green crystal growing in deep stone."}}, "lighting": {"emission": 0.64, "color": "#53e6a3"}, "tags": ["crystal", "gem", "glowing", "rare"]},
	},
	"copper_ore": {
		"id": 37, "content_id": "core.copper_ore", "solid": true, "generated": true, "pattern": "veins", "visual_seed": 37037,
		"base": "#514945", "mid": "#9b583d", "dark": "#332b29", "light": "#e29667", "hardness": 26, "harvest_tier": 2, "movement_speed_multiplier": 1.0, "friction": 0.9, "bounce": 0.01,
		"definition": {"content_id": "core.copper_ore", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Copper Ore"}, "description": {"en": "Stone threaded with bright copper veins."}}, "tags": ["stone", "ore", "mineral", "underground"]},
	},
	"moonstone_ore": {
		"id": 38, "content_id": "core.moonstone_ore", "solid": true, "generated": true, "pattern": "veins", "visual_seed": 38038,
		"base": "#41485e", "mid": "#6674a8", "dark": "#252a3d", "light": "#b9c8ff", "hardness": 34, "harvest_tier": 4, "movement_speed_multiplier": 1.0, "friction": 0.9, "bounce": 0.02,
		"definition": {"content_id": "core.moonstone_ore", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Moonstone Ore"}, "description": {"en": "A blue mineral that glimmers in the deepest caves."}}, "lighting": {"emission": 0.38, "color": "#829cff"}, "tags": ["stone", "ore", "mineral", "glowing", "rare"]},
	},
	"crystal_pickaxe": {
		"id": 39, "content_id": "core.item.crystal_pickaxe", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#62452f", "light": "#d9a8ff", "dark": "#41265f",
		"definition": {"content_id": "core.item.crystal_pickaxe", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Crystal Pickaxe"}, "description": {"en": "An amethyst-edged pickaxe that harvests obsidian and mines 65% faster."}}, "visual": {"shape": "pickaxe", "pattern": "glowing", "palette": ["#62452f", "#925bd0", "#e1b8ff"]}, "category": "mining_tool", "rarity": "uncommon", "effects": {"mining_speed_multiplier": 1.65, "harvest_tier": 4, "creature_damage": 2, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 190}, "requirements": {"ingredient_hardness": 0.8, "generated_ingredient_count": 0}, "tags": ["item", "mining_tool", "crystal", "amethyst", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"moonstone_boots": {
		"id": 40, "content_id": "core.item.moonstone_boots", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#374166", "light": "#d0d9ff", "dark": "#20263f",
		"definition": {"content_id": "core.item.moonstone_boots", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Moonstone Boots"}, "description": {"en": "Light crystal footwear that improves speed by 34% and jumping by 18%."}}, "visual": {"shape": "boots", "pattern": "glowing", "palette": ["#374166", "#829cff", "#ffc1e5"]}, "category": "mobility_tool", "rarity": "rare", "effects": {"mining_speed_multiplier": 1.0, "creature_damage": 1, "movement_speed_multiplier": 1.34, "jump_power_multiplier": 1.18}, "durability": {"max_uses": 320, "distance_per_use": 9.0}, "requirements": {"ingredient_hardness": 0.9, "generated_ingredient_count": 0}, "tags": ["item", "mobility_tool", "boots", "moonstone", "crystal", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"crystal_bricks": {
		"id": 41, "content_id": "core.crystal_bricks", "solid": true, "generated": true, "pattern": "layers", "visual_seed": 41041,
		"base": "#72489a", "mid": "#a56bd0", "dark": "#422957", "light": "#efc9ff", "hardness": 36, "movement_speed_multiplier": 1.0, "friction": 0.9, "bounce": 0.04,
		"definition": {"content_id": "core.crystal_bricks", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Crystal Bricks"}, "description": {"en": "Polished violet masonry made from amethyst and stone."}}, "lighting": {"emission": 0.32, "color": "#c68cff"}, "tags": ["crystal", "brick", "crafted", "glowing"]},
	},
	"crystal_lantern": {
		"id": 42, "content_id": "core.crystal_lantern", "solid": true, "generated": true, "pattern": "runes", "visual_seed": 42042,
		"base": "#773b69", "mid": "#d765ad", "dark": "#3c1d39", "light": "#ffd6f0", "hardness": 14, "movement_speed_multiplier": 1.0, "friction": 0.84, "bounce": 0.03,
		"flammability": 0.0, "temperature": 0.08,
		"definition": {"content_id": "core.crystal_lantern", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Crystal Lantern"}, "description": {"en": "A rose-crystal lamp that bathes caves in soft pink light."}}, "lighting": {"emission": 1.0, "color": "#ff79bd"}, "tags": ["crystal", "crafted", "light_source", "glowing"]},
	},
	"workbench": {
		"id": 43, "content_id": "core.workbench", "solid": true, "station": "workbench",
		"base": "#8b542b", "mid": "#b5793b", "dark": "#4f2d19", "light": "#dda05d",
		"hardness": 12, "movement_speed_multiplier": 1.0, "friction": 0.88, "bounce": 0.02,
		"flammability": 0.82, "temperature": 0.0,
		"definition": {"content_id": "core.workbench", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Workbench"}, "description": {"en": "Place it nearby to craft advanced tools."}}, "tags": ["wood", "crafted", "station", "workbench"]},
	},
	"furnace": {
		"id": 44, "content_id": "core.furnace", "solid": true, "station": "furnace",
		"base": "#57575f", "mid": "#6e6f78", "dark": "#303139", "light": "#a0a1aa",
		"hardness": 30, "harvest_tier": 1, "movement_speed_multiplier": 1.0, "friction": 0.92, "bounce": 0.01,
		"definition": {"content_id": "core.furnace", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Furnace"}, "description": {"en": "Place it nearby to smelt ore into useful metal."}}, "tags": ["stone", "crafted", "station", "furnace"]},
	},
	"copper_ingot": {
		"id": 45, "content_id": "core.item.copper_ingot", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#a95d3d", "mid": "#ca7950", "dark": "#613522", "light": "#f1a272",
		"definition": {"content_id": "core.item.copper_ingot", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Copper Ingot"}, "description": {"en": "Copper ore refined in a nearby furnace."}}, "visual": {"shape": "ingot", "pattern": "metal", "palette": ["#a95d3d", "#ca7950", "#f1a272"]}, "category": "material", "rarity": "common", "tags": ["item", "metal", "copper", "smelted"]},
	},
	"copper_pickaxe": {
		"id": 46, "content_id": "core.item.copper_pickaxe", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#6b4423", "light": "#e29667", "dark": "#56301f",
		"definition": {"content_id": "core.item.copper_pickaxe", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Copper Pickaxe"}, "description": {"en": "A refined pickaxe that harvests crystals and mines 50% faster."}}, "visual": {"shape": "pickaxe", "pattern": "metal", "palette": ["#6b4423", "#b96845", "#f0a173"]}, "category": "mining_tool", "rarity": "uncommon", "effects": {"mining_speed_multiplier": 1.5, "harvest_tier": 3, "creature_damage": 2, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 150}, "tags": ["item", "mining_tool", "copper", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"wild_berries": {
		"id": 47, "content_id": "core.item.wild_berries", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#6f294d", "light": "#ef7198", "dark": "#3d1730",
		"definition": {"content_id": "core.item.wild_berries", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Wild Berries"}, "description": {"en": "A tart handful gathered from leafy trees. Restores 28 nourishment."}}, "visual": {"shape": "berries", "pattern": "organic", "palette": ["#3f7d42", "#b82f67", "#ef7198"]}, "category": "food", "rarity": "common", "effects": {"nourishment": 28}, "tags": ["item", "food", "foraged", "berries"], "mechanics": ["consume"]},
	},
	"prepared_meal": {
		"id": 48, "content_id": "core.item.prepared_meal", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#58432d", "light": "#f2c45f", "dark": "#29231d",
		"definition": {"content_id": "core.item.prepared_meal", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Prepared Meal"}, "description": {"en": "A warm meal prepared at a furnace from one sufficiently large collectible creature. Restores 64 nourishment."}}, "visual": {"shape": "meal", "pattern": "organic", "palette": ["#58432d", "#d88a3d", "#f2c45f"]}, "category": "food", "rarity": "common", "effects": {"nourishment": 64}, "tags": ["item", "food", "prepared", "meal"], "mechanics": ["consume"]},
	},
	"aegisite_seal": {
		"id": 49, "content_id": "core.aegisite_seal", "solid": true, "generated": true,
		"pattern": "runes", "visual_seed": 49049,
		"base": "#171a2a", "mid": "#34304f", "dark": "#090b13", "light": "#8ee7d0",
		"hardness": 110, "harvest_tier": 6, "movement_speed_multiplier": 1.0, "friction": 0.94, "bounce": 0.01,
		"definition": {"content_id": "core.aegisite_seal", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Aegisite Seal"}, "description": {"en": "An ancient resonant barrier. Only a Resonance Pickaxe can break it."}}, "lighting": {"emission": 0.32, "color": "#79e6cf"}, "tags": ["aegisite", "seal", "resonant", "ancient", "deep"]},
	},
	"resonance_pickaxe": {
		"id": 50, "content_id": "core.item.resonance_pickaxe", "solid": false, "fluid": false, "item": true,
		"hardness": 1, "base": "#9f6f48", "light": "#84f3d5", "dark": "#3f2a24",
		"definition": {"content_id": "core.item.resonance_pickaxe", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Resonance Pickaxe"}, "description": {"en": "A legendary late-game pickaxe that breaks Aegisite Seals and mines at twelve times normal speed."}}, "visual": {"shape": "pickaxe", "pattern": "glowing", "palette": ["#b98555", "#58d8bf", "#d4fff2"]}, "category": "mining_tool", "rarity": "legendary", "effects": {"mining_speed_multiplier": 12.0, "harvest_tier": 6, "creature_damage": 3, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 420}, "tags": ["item", "mining_tool", "resonant", "aegisite", "crafted"], "mechanics": ["hotbar_active"]},
	},
	"lumenroot": {
		"id": 51, "content_id": "core.lumenroot", "solid": true, "generated": true,
		"pattern": "organic", "visual_seed": 51051,
		"base": "#21493f", "mid": "#397d65", "dark": "#10261f", "light": "#b7ff8a",
		"hardness": 12, "movement_speed_multiplier": 0.9, "friction": 0.8, "bounce": 0.04,
		"definition": {"content_id": "core.lumenroot", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Lumenroot"}, "description": {"en": "A living deep root that stores and softly reflects the Deep's ambient light."}}, "lighting": {"emission": 0.0, "color": "#a9ff78"}, "tags": ["plant", "root", "glowing", "resonant", "deep"]},
	},
	"glass_tide": {
		"id": 52, "content_id": "core.glass_tide", "solid": false, "fluid": true, "decay": 2, "tick_rate": 17,
		"deep": "#31546f", "base": "#5b91a7", "light": "#c7f5ef", "hardness": 6,
		"definition": {"content_id": "core.glass_tide", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Glass-Tide"}, "description": {"en": "A crystalline liquid that can be redirected and cooled into bridges."}}, "lighting": {"emission": 0.45, "color": "#a8f2ed"}, "tags": ["fluid", "crystal", "resonant", "deep"]},
	},
	"magnetic_stone": {
		"id": 53, "content_id": "core.magnetic_stone", "solid": true, "generated": true,
		"pattern": "veins", "visual_seed": 53053,
		"base": "#34383c", "mid": "#454b50", "dark": "#1c2023", "light": "#79888a",
		"hardness": 44, "harvest_tier": 5, "movement_speed_multiplier": 1.0, "friction": 0.94, "bounce": 0.02,
		"definition": {"content_id": "core.magnetic_stone", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Lodestone"}, "description": {"en": "A rough natural rock threaded with pale magnetic mineral veins."}}, "tags": ["stone", "ore", "mineral", "magnetic", "resonant", "deep"]},
	},
	"resonance_bricks": {
		"id": 54, "content_id": "core.resonance_bricks", "solid": true, "generated": true,
		"pattern": "layers", "visual_seed": 54054,
		"base": "#3b344d", "mid": "#594d6d", "dark": "#211c2d", "light": "#75dcca",
		"hardness": 34, "harvest_tier": 4, "movement_speed_multiplier": 1.0, "friction": 0.9, "bounce": 0.02,
		"definition": {"content_id": "core.resonance_bricks", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Resonance Bricks"}, "description": {"en": "Carefully fitted reflective masonry used by Shagots in the Resonant Deep."}}, "lighting": {"emission": 0.0, "color": "#70d8c4"}, "tags": ["brick", "crafted", "resonant", "shagot", "deep"]},
	},
	"shagot_scaffold": {
		"id": 55, "content_id": "core.shagot_scaffold", "solid": true, "generated": true,
		"pattern": "runes", "visual_seed": 55055,
		"base": "#322d43", "mid": "#5d536f", "dark": "#191725", "light": "#8ff3d5",
		"hardness": 20, "movement_speed_multiplier": 1.0, "friction": 0.9, "bounce": 0.02,
		"definition": {"content_id": "core.shagot_scaffold", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Shagot Scaffold"}, "description": {"en": "A reflective, walk-through framework assembled by working Shagots."}}, "lighting": {"emission": 0.0, "color": "#77e4ca"}, "tags": ["scaffold", "passage", "crafted", "resonant", "shagot", "deep"]},
	},
	"glass_tide_silt": {
		"id": 56, "content_id": "core.glass_tide_silt", "solid": true, "generated": true,
		"pattern": "layers", "visual_seed": 56056,
		"base": "#263c4a", "mid": "#36596a", "dark": "#152732", "light": "#6f9ea8",
		"hardness": 28, "harvest_tier": 4, "movement_speed_multiplier": 0.96, "friction": 0.76, "bounce": 0.03,
		"definition": {"content_id": "core.glass_tide_silt", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Glass-Tide Silt"}, "description": {"en": "Layered cavern sediment polished smooth by crystalline currents."}}, "lighting": {"emission": 0.0, "color": "#91d9de"}, "tags": ["stone", "sediment", "crystal", "deep"]},
	},
	"prismatic_basalt": {
		"id": 57, "content_id": "core.prismatic_basalt", "solid": true, "generated": true,
		"pattern": "cracks", "visual_seed": 57057,
		"base": "#352d47", "mid": "#4c3d61", "dark": "#1d1829", "light": "#8b719e",
		"hardness": 48, "harvest_tier": 5, "movement_speed_multiplier": 1.0, "friction": 0.92, "bounce": 0.02,
		"definition": {"content_id": "core.prismatic_basalt", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Prismatic Basalt"}, "description": {"en": "Dark volcanic stone fractured by slow-growing crystal seams."}}, "lighting": {"emission": 0.0, "color": "#c195d6"}, "tags": ["stone", "basalt", "crystal", "deep"]},
	},
	"tideglass": {
		"id": 58, "content_id": "core.tideglass", "solid": true, "generated": true,
		"base": "#8bd3dd", "mid": "#5aa7b7", "dark": "#2c6174", "light": "#dcfff8",
		"hardness": 18, "harvest_tier": 3, "movement_speed_multiplier": 1.04, "friction": 0.32, "bounce": 0.03,
		"flammability": 0.0, "temperature": -0.15,
		"lighting": {"emission": 0.32, "color": "#a8f2ed"},
		"tags": ["glass", "crystal", "bridge", "resonant", "frozen", "deep"],
		"definition": {"content_id": "core.tideglass", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Tideglass"}, "description": {"en": "Glass-Tide crystallized by Packed Ice into a luminous bridge. Strong heat melts it back into flowing Glass-Tide."}}},
	},
	"chorus_brine": {
		"id": 59, "content_id": "core.chorus_brine", "solid": false, "fluid": true, "decay": 1, "tick_rate": 11,
		"deep": "#241b50", "base": "#684bb5", "light": "#76f5e2", "hardness": 8,
		"viscosity": 0.22, "current_strength": 0.82,
		"definition": {"content_id": "core.chorus_brine", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Chorus Brine"}, "description": {"en": "A resonant underground river whose powerful current charges nearby Chorus Crystals."}}},
		"lighting": {"emission": 0.18, "color": "#7cebdc"}, "tags": ["fluid", "river", "crystal", "resonant", "current", "deep"],
	},
	"chorus_crystal": {
		"id": 60, "content_id": "core.chorus_crystal", "solid": true, "generated": true,
		"pattern": "runes", "visual_seed": 60060,
		"base": "#41306f", "mid": "#7256bd", "dark": "#201638", "light": "#8fffe7",
		"hardness": 42, "harvest_tier": 5, "movement_speed_multiplier": 1.0, "friction": 0.84, "bounce": 0.12,
		"definition": {"content_id": "core.chorus_crystal", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Chorus Crystal"}, "description": {"en": "A river crystal that hums and brightens when Chorus Brine flows past it."}}},
		"lighting": {"emission": 0.62, "color": "#77f3df"}, "tags": ["crystal", "resonant", "river", "glowing", "deep"],
	},
	"inverted_root": {
		"id": 61, "content_id": "core.inverted_root", "solid": true, "generated": true,
		"pattern": "organic", "visual_seed": 61061,
		"base": "#493357", "mid": "#76527c", "dark": "#241a30", "light": "#d7a9e2",
		"hardness": 16, "movement_speed_multiplier": 0.94, "friction": 0.82, "bounce": 0.05,
		"definition": {"content_id": "core.inverted_root", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Inverted Root"}, "description": {"en": "A woody root that grows downward from the cavern roof and bears luminous crystal fruit."}}},
		"lighting": {"emission": 0.0, "color": "#d8a8e7"}, "tags": ["plant", "root", "wood", "hanging", "deep"],
	},
	"choir_bone": {
		"id": 62, "content_id": "core.choir_bone", "solid": true, "generated": true,
		"pattern": "layers", "visual_seed": 62062,
		"base": "#8b8093", "mid": "#b9adc0", "dark": "#4a4354", "light": "#efe3ed",
		"hardness": 38, "harvest_tier": 4, "movement_speed_multiplier": 1.0, "friction": 0.88, "bounce": 0.06,
		"definition": {"content_id": "core.choir_bone", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Choir Bone"}, "description": {"en": "A hollow fossil rib that sings when the Deep's air passes through it."}}},
		"tags": ["bone", "fossil", "hollow", "ancient", "deep"],
	},
	"choir_vent": {
		"id": 63, "content_id": "core.choir_vent", "solid": true, "generated": true,
		"pattern": "runes", "visual_seed": 63063,
		"base": "#5c5268", "mid": "#9689a0", "dark": "#302a39", "light": "#d8fff4",
		"hardness": 28, "harvest_tier": 4, "movement_speed_multiplier": 1.08, "friction": 0.5, "bounce": 0.92,
		"definition": {"content_id": "core.choir_vent", "kind": "block", "schema_version": "1.0", "display": {"name": {"en": "Choir Vent"}, "description": {"en": "A resonant fossil vent whose pressure pulse launches anything that lands on it."}}},
		"lighting": {"emission": 0.16, "color": "#c8fff0"}, "tags": ["bone", "vent", "resonant", "launch", "deep"],
	},
	"stick": {
		"id": 64, "content_id": "core.item.stick", "solid": false, "fluid": false, "item": true, "hardness": 1,
		"base": "#76502f", "light": "#d7a264", "dark": "#3f2a1a",
		"definition": {"content_id": "core.item.stick", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Stick"}, "description": {"en": "A straight wooden shaft used for tools and arrows."}}, "visual": {"shape": "stick", "pattern": "plain", "palette": ["#76502f", "#d7a264", "#efc486"]}, "category": "material", "rarity": "common", "tags": ["item", "wood", "material", "crafted"]},
	},
	"string": {
		"id": 65, "content_id": "core.item.string", "solid": false, "fluid": false, "item": true, "hardness": 1,
		"base": "#d8d5cb", "light": "#ffffff", "dark": "#85827a",
		"definition": {"content_id": "core.item.string", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "String"}, "description": {"en": "Strong spider silk used to string a bow."}}, "visual": {"shape": "string", "pattern": "plain", "palette": ["#85827a", "#e8e5dc", "#ffffff"]}, "category": "material", "rarity": "common", "tags": ["item", "fiber", "spider", "material"]},
	},
	"flint": {
		"id": 66, "content_id": "core.item.flint", "solid": false, "fluid": false, "item": true, "hardness": 1,
		"base": "#4f5358", "light": "#b2b8bd", "dark": "#282b2e",
		"definition": {"content_id": "core.item.flint", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Flint"}, "description": {"en": "A sharp stone chip occasionally found while mining gravel."}}, "visual": {"shape": "flint", "pattern": "speckled", "palette": ["#303438", "#777d82", "#c0c5c9"]}, "category": "material", "rarity": "common", "tags": ["item", "stone", "sharp", "material"]},
	},
	"feather": {
		"id": 67, "content_id": "core.item.feather", "solid": false, "fluid": false, "item": true, "hardness": 1,
		"base": "#e8e5dc", "light": "#ffffff", "dark": "#8e929a",
		"definition": {"content_id": "core.item.feather", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Feather"}, "description": {"en": "A light flight feather used to steady arrows."}}, "visual": {"shape": "feather", "pattern": "plain", "palette": ["#767b82", "#e7e5df", "#ffffff"]}, "category": "material", "rarity": "common", "tags": ["item", "feather", "material"]},
	},
	"arrow": {
		"id": 68, "content_id": "core.item.arrow", "solid": false, "fluid": false, "item": true, "hardness": 1,
		"base": "#7b5230", "light": "#e7e5df", "dark": "#34383c",
		"definition": {"content_id": "core.item.arrow", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Arrow"}, "description": {"en": "Ammunition for a bow. Missed arrows can be recovered."}}, "visual": {"shape": "arrow", "pattern": "plain", "palette": ["#7b5230", "#d8d5cb", "#555b61"]}, "category": "ammunition", "rarity": "common", "tags": ["item", "ammunition", "projectile", "crafted"]},
	},
	"bow": {
		"id": 69, "content_id": "core.item.bow", "solid": false, "fluid": false, "item": true, "hardness": 1,
		"base": "#8a5a2e", "light": "#d8d5cb", "dark": "#442b18",
		"definition": {"content_id": "core.item.bow", "kind": "item", "schema_version": "1.0", "display": {"name": {"en": "Bow"}, "description": {"en": "A ranged weapon. Hold the aim stick to draw, then release to fire."}}, "visual": {"shape": "bow", "pattern": "banded", "palette": ["#8a5a2e", "#d8d5cb", "#e9b86e"]}, "category": "weapon", "rarity": "common", "effects": {"mining_speed_multiplier": 1.0, "creature_damage": 1, "movement_speed_multiplier": 1.0, "jump_power_multiplier": 1.0}, "durability": {"max_uses": 384}, "tags": ["item", "weapon", "ranged", "bow", "crafted"], "mechanics": ["hotbar_active", "aim_and_release"]},
	}
}

const RECIPES: Array[Dictionary] = [
	{"in": {"water": 1, "lava": 1}, "out": {"cobblestone": 1}, "label": "Вода + лава → булыжник"},
	{"in": {"cobblestone": 2, "gravel": 2}, "out": {"stone": 1}, "label": "2 булыжника + 2 гравия → камень"},
	{"in": {"dirt": 2, "grass": 1}, "out": {"grass": 3}, "label": "2 земли + трава → 3 травы"},
	{"in": {"leaves": 4}, "out": {"wood": 1}, "label": "4 листа → дерево"},
	{"in": {"cobblestone": 1}, "out": {"gravel": 1}, "label": "Булыжник → гравий"},
	{"in": {"stone": 1}, "out": {"gravel": 1}, "label": "Камень → гравий"},
	{"in": {"gravel": 1}, "out": {"sand": 1}, "label": "Гравий → песок"},
	{"in": {"sand": 1, "lava": 1}, "out": {"glass": 1}, "label": "Песок + лава → стекло"},
	{"in": {"wood": 1, "lava": 1}, "out": {"charcoal": 1}, "label": "Дерево + лава → уголь"},
	{"in": {"wood": 1}, "out": {"planks": 4}, "label": "Дерево → 4 доски"},
	{"in": {"stone": 1, "lava": 1, "water": 1}, "out": {"obsidian": 1}, "label": "Камень + вода + лава → обсидиан"},
	{"in": {"leaves": 2, "planks": 1}, "out": {"trail_boots": 1}, "label": "2 листа + доски → походные ботинки"},
	{"in": {"planks": 3, "wood": 1}, "out": {"chest": 1}, "label": "3 доски + дерево → сундук"},
	{"in": {"planks": 4}, "out": {"workbench": 1}, "label": "4 доски → верстак"},
	{"in": {"cobblestone": 4}, "out": {"furnace": 1}, "label": "4 булыжника → печь"},
]

const CONTENT_RECIPES: Array[Dictionary] = [
	{"in": {"core.planks": 2}, "out": {"core.item.stick": 4}},
	{"in": {"core.palm_planks": 2}, "out": {"core.item.stick": 4}},
	{"in": {"core.pine_planks": 2}, "out": {"core.item.stick": 4}},
	{"in": {"core.weeping_planks": 2}, "out": {"core.item.stick": 4}},
	# Tiny Block's tactile crafting tray has four slots, so the Minecraft 3+3
	# ratio is compressed to an equivalent 2 sticks + 2 string.
	{"in": {"core.item.stick": 2, "core.item.string": 2}, "out": {"core.item.bow": 1}, "station": "workbench"},
	{"in": {"core.item.flint": 1, "core.item.stick": 1, "core.item.feather": 1}, "out": {"core.item.arrow": 4}},
	{"in": {"core.palm_wood": 1}, "out": {"core.palm_planks": 4}},
	{"in": {"core.pine_wood": 1}, "out": {"core.pine_planks": 4}},
	{"in": {"core.weeping_wood": 1}, "out": {"core.weeping_planks": 4}},
	{"in": {"core.palm_leaves": 4}, "out": {"core.palm_wood": 1}},
	{"in": {"core.pine_needles": 4}, "out": {"core.pine_wood": 1}},
	{"in": {"core.weeping_leaves": 4}, "out": {"core.weeping_wood": 1}},
	{"in": {"core.palm_leaves": 2}, "out": {"core.woven_thatch": 2}},
	{"in": {"core.stone": 2}, "out": {"core.stone_bricks": 2}},
	{"in": {"core.sand": 2, "core.stone": 1}, "out": {"core.sandstone": 3}},
	{"in": {"core.ice": 4}, "out": {"core.packed_ice": 1}},
	{"in": {"core.obsidian": 2, "core.stone": 2}, "out": {"core.polished_obsidian": 2}},
	{"in": {"core.charcoal": 1, "core.glass": 1, "core.stone": 1}, "out": {"core.lantern": 1}},
	{"in": {"core.palm_planks": 3, "core.palm_wood": 1}, "out": {"core.chest": 1}},
	{"in": {"core.pine_planks": 3, "core.pine_wood": 1}, "out": {"core.chest": 1}},
	{"in": {"core.weeping_planks": 3, "core.weeping_wood": 1}, "out": {"core.chest": 1}},
	{"in": {"core.palm_planks": 4}, "out": {"core.workbench": 1}},
	{"in": {"core.pine_planks": 4}, "out": {"core.workbench": 1}},
	{"in": {"core.weeping_planks": 4}, "out": {"core.workbench": 1}},
	{"in": {"core.planks": 3}, "out": {"core.item.wooden_pickaxe": 1}},
	{"in": {"core.palm_planks": 3}, "out": {"core.item.wooden_pickaxe": 1}},
	{"in": {"core.pine_planks": 3}, "out": {"core.item.wooden_pickaxe": 1}},
	{"in": {"core.weeping_planks": 3}, "out": {"core.item.wooden_pickaxe": 1}},
	{"in": {"core.planks": 1, "core.cobblestone": 2, "core.wood": 1}, "out": {"core.item.stone_axe": 1}, "station": "workbench"},
	{"in": {"core.palm_planks": 1, "core.cobblestone": 2, "core.palm_wood": 1}, "out": {"core.item.stone_axe": 1}, "station": "workbench"},
	{"in": {"core.pine_planks": 1, "core.cobblestone": 2, "core.pine_wood": 1}, "out": {"core.item.stone_axe": 1}, "station": "workbench"},
	{"in": {"core.weeping_planks": 1, "core.cobblestone": 2, "core.weeping_wood": 1}, "out": {"core.item.stone_axe": 1}, "station": "workbench"},
	{"in": {"core.planks": 1, "core.stone": 2}, "out": {"core.item.stone_sword": 1}, "station": "workbench"},
	{"in": {"core.palm_planks": 1, "core.stone": 2}, "out": {"core.item.stone_sword": 1}, "station": "workbench"},
	{"in": {"core.pine_planks": 1, "core.stone": 2}, "out": {"core.item.stone_sword": 1}, "station": "workbench"},
	{"in": {"core.weeping_planks": 1, "core.stone": 2}, "out": {"core.item.stone_sword": 1}, "station": "workbench"},
	{"in": {"core.palm_leaves": 2, "core.palm_planks": 1}, "out": {"core.item.palm_sandals": 1}},
	{"in": {"core.ice": 2, "core.pine_planks": 1}, "out": {"core.item.ice_boots": 1}},
	{"in": {"core.planks": 2, "core.cobblestone": 2}, "out": {"core.item.stone_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.palm_planks": 2, "core.cobblestone": 2}, "out": {"core.item.stone_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.pine_planks": 2, "core.cobblestone": 2}, "out": {"core.item.stone_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.weeping_planks": 2, "core.cobblestone": 2}, "out": {"core.item.stone_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.copper_ore": 1, "core.charcoal": 1}, "out": {"core.item.copper_ingot": 1}, "station": "furnace"},
	{"in": {"core.item.stone_pickaxe": 1, "core.item.copper_ingot": 2, "core.planks": 1}, "out": {"core.item.copper_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.item.stone_pickaxe": 1, "core.item.copper_ingot": 2, "core.palm_planks": 1}, "out": {"core.item.copper_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.item.stone_pickaxe": 1, "core.item.copper_ingot": 2, "core.pine_planks": 1}, "out": {"core.item.copper_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.item.stone_pickaxe": 1, "core.item.copper_ingot": 2, "core.weeping_planks": 1}, "out": {"core.item.copper_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.item.copper_pickaxe": 1, "core.amethyst_crystal": 2, "core.item.copper_ingot": 1}, "out": {"core.item.crystal_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.item.crystal_pickaxe": 1, "core.obsidian": 2, "core.moonstone_ore": 1}, "out": {"core.item.obsidian_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.moonstone_ore": 2, "core.rose_crystal": 1}, "out": {"core.item.moonstone_boots": 1}},
	{"in": {"core.amethyst_crystal": 1, "core.stone": 1}, "out": {"core.crystal_bricks": 2}},
	{"in": {"core.rose_crystal": 1, "core.glass": 1, "core.charcoal": 1}, "out": {"core.crystal_lantern": 1}},
	{"in": {"core.item.obsidian_pickaxe": 1, "core.emerald_crystal": 1, "core.moonstone_ore": 1, "core.rose_crystal": 1}, "out": {"core.item.resonance_pickaxe": 1}, "station": "workbench"},
	{"in": {"core.magnetic_stone": 2, "core.lumenroot": 1}, "out": {"core.resonance_bricks": 2}},
]

var block_by_id: Dictionary = {}
var block_name_by_content_id: Dictionary = {}
var generated_definitions: Dictionary = {}
var tree_component_content_ids: Dictionary = {}


func _ready() -> void:
	for block_name: String in BLOCKS:
		var entry: Dictionary = BLOCKS[block_name].duplicate()
		entry["name"] = block_name
		entry["content_id"] = str(entry.get("content_id", "core.%s" % block_name))
		block_by_id[BLOCKS[block_name]["id"]] = entry
		block_name_by_content_id[entry["content_id"]] = block_name


func content_id_for_name(block_name: String) -> String:
	return str(BLOCKS.get(block_name, {}).get("content_id", "core.%s" % block_name))


func name_for_content_id(content_id: String) -> String:
	return str(block_name_by_content_id.get(content_id, ""))


func register_generated_block(definition: Dictionary) -> String:
	var content_id := str(definition.get("content_id", ""))
	if content_id.is_empty():
		return ""
	var replacement_id := -1
	if block_name_by_content_id.has(content_id):
		var existing_name := str(block_name_by_content_id[content_id])
		var existing: Dictionary = BLOCKS.get(existing_name, {})
		var existing_definition: Dictionary = existing.get("definition", {}) if existing.get("definition", {}) is Dictionary else {}
		var incoming_kind := str(definition.get("kind", "block"))
		var existing_kind := str(existing_definition.get("kind", "block"))
		if existing.get("generated", false) and incoming_kind == "block" and existing_kind == "block":
			_apply_generated_block_visual(existing, definition, content_id)
			existing["definition"] = definition.duplicate(true)
			BLOCKS[existing_name] = existing
			block_by_id[int(existing["id"])] = existing
			generated_definitions[content_id] = definition.duplicate(true)
			return existing_name
		if existing.get("generated", false):
			replacement_id = int(existing.get("id", -1))
	var digest := content_id.sha256_text().substr(0, 12)
	var block_name := "generated_%s" % digest
	var registered_name := ""
	if str(definition.get("kind", "block")) == "plant":
		registered_name = _register_generated_plant(block_name, content_id, definition)
	elif str(definition.get("kind", "block")) == "creature":
		registered_name = _register_generated_creature(block_name, content_id, definition)
	elif str(definition.get("kind", "block")) == "item":
		registered_name = _register_generated_item(block_name, content_id, definition)
	if not registered_name.is_empty():
		_reuse_generated_block_id(registered_name, replacement_id)
		return registered_name
	var components: Dictionary = definition.get("components", {}) if definition.get("components", {}) is Dictionary else {}
	var balance: Dictionary = definition.get("balance", {}) if definition.get("balance", {}) is Dictionary else {}
	var surface: Dictionary = definition.get("surface", {}) if definition.get("surface", {}) is Dictionary else {}
	var material: Dictionary = definition.get("material", {}) if definition.get("material", {}) is Dictionary else {}
	var physics: Dictionary = definition.get("physics", {}) if definition.get("physics", {}) is Dictionary else {}
	var phase := str(material.get("phase", "solid" if bool(components.get("solid", true)) else "liquid"))
	var is_liquid := phase == "liquid"
	var viscosity := clampf(float(material.get("viscosity", 0.15 if is_liquid else 0.0)), 0.0, 1.0)
	var falls_when_unsupported := false if is_liquid else bool(physics.get("falls_when_unsupported", false))
	var settles_diagonally := falls_when_unsupported and bool(physics.get("settles_diagonally", false))
	var visual_seed := posmod(content_id.hash(), 1000000)
	var pattern := _generated_pattern(definition, visual_seed)
	var entry := {
		"id": _next_block_id(),
		"name": block_name,
		"content_id": content_id,
		"solid": false if is_liquid else bool(components.get("solid", true)),
		"fluid": is_liquid,
		"decay": maxi(1, int(round(1.0 + viscosity * 2.0))),
		"tick_rate": maxi(4, int(round(5.0 + viscosity * 36.0))),
		"material_phase": phase,
		"material_hardness": clampf(float(material.get("hardness", 0.5)), 0.0, 1.0),
		"viscosity": viscosity,
		"elasticity": clampf(float(material.get("elasticity", 0.05)), 0.0, 1.0),
		"flammability": clampf(float(material.get("flammability", 0.0)), 0.0, 1.0),
		"temperature": clampf(float(material.get("temperature", 0.0)), -1.0, 1.0),
		"falls_when_unsupported": falls_when_unsupported,
		"settles_diagonally": settles_diagonally,
		"base": "#888888", "mid": "#777777", "dark": "#555555", "light": "#aaaaaa",
		"hardness": maxi(1, int(balance.get("hardness", 8))),
		"movement_speed_multiplier": clampf(float(surface.get("movement_speed_multiplier", 1.0)), 0.35, 1.75),
		"friction": clampf(float(surface.get("friction", 1.0)), 0.0, 1.0),
		"bounce": clampf(float(surface.get("bounce", 0.0)), 0.0, 1.0),
		"generated": true,
		"visual_seed": visual_seed,
		"pattern": pattern,
		"definition": definition.duplicate(true),
	}
	_apply_generated_block_visual(entry, definition, content_id)
	BLOCKS[block_name] = entry
	block_by_id[entry["id"]] = entry
	block_name_by_content_id[content_id] = block_name
	generated_definitions[content_id] = definition.duplicate(true)
	_reuse_generated_block_id(block_name, replacement_id)
	return block_name


func _reuse_generated_block_id(block_name: String, replacement_id: int) -> void:
	if replacement_id < 0 or not BLOCKS.has(block_name):
		return
	var entry: Dictionary = BLOCKS[block_name]
	var allocated_id := int(entry.get("id", replacement_id))
	if allocated_id != replacement_id:
		block_by_id.erase(allocated_id)
	entry["id"] = replacement_id
	BLOCKS[block_name] = entry
	block_by_id[replacement_id] = entry


func _apply_generated_block_visual(entry: Dictionary, definition: Dictionary, content_id: String) -> void:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var palette: Array = visual.get("palette", []) if visual.get("palette", []) is Array else []
	if palette.is_empty() and LEGACY_GENERATED_PALETTES.has(content_id):
		palette = LEGACY_GENERATED_PALETTES[content_id]
	var hue := float(abs(content_id.hash()) % 1000) / 1000.0
	var fallback := Color.from_hsv(hue, 0.52, 0.82)
	var base := Color(str(palette[0])) if palette.size() > 0 and Color.html_is_valid(str(palette[0])) else fallback
	var accent := Color(str(palette[1])) if palette.size() > 1 and Color.html_is_valid(str(palette[1])) else base.lightened(0.22)
	var dark := Color(str(palette[2])) if palette.size() > 2 and Color.html_is_valid(str(palette[2])) else base.darkened(0.28)
	var light := Color(str(palette[3])) if palette.size() > 3 and Color.html_is_valid(str(palette[3])) else accent
	entry["base"] = base.to_html(false)
	entry["mid"] = base.lerp(accent, 0.38).to_html(false)
	entry["dark"] = dark.to_html(false)
	entry["light"] = light.to_html(false)
	entry["visual_seed"] = posmod(content_id.hash(), 1000000)
	entry["pattern"] = _generated_pattern(definition, int(entry["visual_seed"]))


func _register_generated_plant(block_name: String, content_id: String, definition: Dictionary) -> String:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var palette: Array = visual.get("palette", []) if visual.get("palette", []) is Array else []
	var base := Color(str(palette[0])) if palette.size() > 0 and Color.html_is_valid(str(palette[0])) else Color("#2b7d3b")
	var light := Color(str(palette[1])) if palette.size() > 1 and Color.html_is_valid(str(palette[1])) else Color("#9adf45")
	var detail := Color(str(palette[2])) if palette.size() > 2 and Color.html_is_valid(str(palette[2])) else Color("#e67e36")
	var entry := {
		"id": _next_block_id(), "name": block_name, "content_id": content_id,
		"solid": false, "fluid": false, "plant": true, "generated": true,
		"base": base.to_html(false), "mid": base.lightened(0.12).to_html(false),
		"dark": base.darkened(0.28).to_html(false), "light": light.to_html(false), "detail": detail.to_html(false),
		"hardness": 3, "movement_speed_multiplier": 1.0, "friction": 1.0, "bounce": 0.0,
		"visual_seed": posmod(content_id.hash(), 1000000), "pattern": str(visual.get("pattern", "organic")),
		"definition": definition.duplicate(true),
	}
	BLOCKS[block_name] = entry
	block_by_id[entry["id"]] = entry
	block_name_by_content_id[content_id] = block_name
	generated_definitions[content_id] = definition.duplicate(true)
	var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
	if str(growth.get("form", "")) == "tree":
		var components: Dictionary = definition.get("tree_components", {}) if definition.get("tree_components", {}) is Dictionary else {}
		for field in ["trunk_content_id", "foliage_content_id"]:
			var component_id := str(components.get(field, ""))
			if not component_id.is_empty():
				tree_component_content_ids[component_id] = true
	return block_name


func _register_generated_creature(block_name: String, content_id: String, definition: Dictionary) -> String:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var palette: Array = visual.get("palette", []) if visual.get("palette", []) is Array else []
	var base := Color(str(palette[0])) if palette.size() > 0 and Color.html_is_valid(str(palette[0])) else Color("#77543a")
	var light := Color(str(palette[1])) if palette.size() > 1 and Color.html_is_valid(str(palette[1])) else Color("#f2c14e")
	var entry := {
		"id": _next_block_id(), "name": block_name, "content_id": content_id,
		"solid": false, "fluid": false, "creature_item": true, "generated": true,
		"base": base.to_html(false), "mid": base.lightened(0.12).to_html(false),
		"dark": base.darkened(0.3).to_html(false), "light": light.to_html(false),
		"hardness": 1, "definition": definition.duplicate(true),
	}
	BLOCKS[block_name] = entry
	block_by_id[entry["id"]] = entry
	block_name_by_content_id[content_id] = block_name
	generated_definitions[content_id] = definition.duplicate(true)
	return block_name


func _register_generated_item(block_name: String, content_id: String, definition: Dictionary) -> String:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var palette: Array = visual.get("palette", []) if visual.get("palette", []) is Array else []
	var base := Color(str(palette[0])) if palette.size() > 0 and Color.html_is_valid(str(palette[0])) else Color("#5b4630")
	var light := Color(str(palette[1])) if palette.size() > 1 and Color.html_is_valid(str(palette[1])) else Color("#d7b45a")
	var entry := {
		"id": _next_block_id(), "name": block_name, "content_id": content_id,
		"solid": false, "fluid": false, "item": true, "generated": true,
		"base": base.to_html(false), "light": light.to_html(false), "dark": base.darkened(0.3).to_html(false),
		"hardness": 1, "definition": definition.duplicate(true),
	}
	BLOCKS[block_name] = entry
	block_by_id[entry["id"]] = entry
	block_name_by_content_id[content_id] = block_name
	generated_definitions[content_id] = definition.duplicate(true)
	return block_name


func export_generated_definitions() -> Array:
	var out: Array = []
	for definition in generated_definitions.values():
		out.append((definition as Dictionary).duplicate(true))
	return out


func _next_block_id() -> int:
	var highest := 0
	for raw_id in block_by_id.keys():
		highest = maxi(highest, int(raw_id))
	return highest + 1


func _generated_pattern(definition: Dictionary, visual_seed: int) -> String:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var requested := str(visual.get("pattern", ""))
	if requested in GENERATED_PATTERNS:
		return requested
	var tag_text := " ".join(Array(definition.get("tags", []))).to_lower()
	if "crystal" in tag_text or "gem" in tag_text or "glass" in tag_text:
		return "crystals"
	if "plant" in tag_text or "leaf" in tag_text or "organic" in tag_text or "moss" in tag_text:
		return "organic"
	if "bubble" in tag_text or "foam" in tag_text or "slime" in tag_text:
		return "bubbles"
	if "scale" in tag_text or "shell" in tag_text or "reptile" in tag_text:
		return "scales"
	if "cell" in tag_text or "honey" in tag_text or "coral" in tag_text:
		return "cells"
	if "magic" in tag_text or "rune" in tag_text or "arcane" in tag_text or "enchanted" in tag_text:
		return "runes"
	if "metal" in tag_text or "alloy" in tag_text or "machine" in tag_text:
		return "metal"
	if "ore" in tag_text or "mineral" in tag_text:
		return "veins"
	if "crack" in tag_text or "dry" in tag_text or "brittle" in tag_text:
		return "cracks"
	if "fiber" in tag_text or "fabric" in tag_text or "striped" in tag_text:
		return "stripes"
	return GENERATED_PATTERNS[posmod(visual_seed, GENERATED_PATTERNS.size())]


func get_block_by_id(id: int) -> Dictionary:
	if block_by_id.has(id):
		return block_by_id[id]
	return BLOCKS["air"]


func get_block_name(id: int) -> String:
	var b := get_block_by_id(id)
	return b.get("name", "air")


func preview_color(block: Dictionary) -> Color:
	var hex: String = block.get("top", block.get("base", block.get("mid", block.get("side", "#888888"))))
	return Color(hex)


func hash2(a: int, b: int) -> float:
	return float(((a * 374761 + b * 668265) & 0xffff)) / 65535.0


func world_hash(tx: int, ty: int, lx: int, ly: int) -> float:
	return hash2(tx * TILE + lx, ty * TILE + ly)


func _tile_rect(x: float, y: float, sx: float, sy: float, lx: float, ly: float, lw: float, lh: float) -> Rect2:
	return Rect2(x + lx * sx, y + ly * sy, lw * sx, lh * sy)


func _safe_rect(
	x: float,
	y: float,
	sx: float,
	sy: float,
	lx: float,
	ly: float,
	lw: float,
	lh: float,
	pad: float = 1.0
) -> Rect2:
	var left: float = maxf(lx, pad)
	var top: float = maxf(ly, pad)
	var right: float = minf(lx + lw, float(TILE) - pad)
	var bottom: float = minf(ly + lh, float(TILE) - pad)
	if right <= left or bottom <= top:
		return Rect2()
	return _tile_rect(x, y, sx, sy, left, top, right - left, bottom - top)


func _draw_safe(
	canvas: CanvasItem,
	x: float,
	y: float,
	sx: float,
	sy: float,
	lx: float,
	ly: float,
	lw: float,
	lh: float,
	color: Color,
	pad: float = 1.0
) -> void:
	var rect := _safe_rect(x, y, sx, sy, lx, ly, lw, lh, pad)
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		canvas.draw_rect(rect, color)


func _edge_bevel(
	canvas: CanvasItem,
	x: float,
	y: float,
	w: float,
	h: float,
	sx: float,
	sy: float,
	modulate: Color,
	mask: int
) -> void:
	var shadow_w: float = maxf(3.0 * sx, 1.0)
	var shadow_h: float = maxf(3.0 * sy, 1.0)
	var highlight: float = maxf(2.0 * sx, 1.0)
	var highlight_y: float = maxf(2.0 * sy, 1.0)
	if mask & BEVEL_RIGHT:
		canvas.draw_rect(Rect2(x + w - shadow_w, y, shadow_w, h), Color(0, 0, 0, 0.14 * modulate.a))
	if mask & BEVEL_BOTTOM:
		canvas.draw_rect(Rect2(x, y + h - shadow_h, w, shadow_h), Color(0, 0, 0, 0.14 * modulate.a))
	if mask & BEVEL_TOP:
		canvas.draw_rect(Rect2(x, y, w, highlight_y), Color(1, 0.94, 0.78, 0.12 * modulate.a))
	if mask & BEVEL_LEFT:
		canvas.draw_rect(Rect2(x, y, highlight, h), Color(1, 0.96, 0.84, 0.095 * modulate.a))


func _draw_grass(canvas: CanvasItem, tx: int, ty: int, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	canvas.draw_rect(Rect2(x, y, w, h), _c(BLOCKS.dirt, "base") * modulate)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 0, 0, TILE, 11), _c(block, "top") * modulate)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 0, 7, TILE, 5), _c(block, "mid") * modulate)
	for i in 6:
		var blade_x: float = 3.0 + floorf(hash2(tx + i * 13, ty + 5) * 24.0)
		var blade_h: float = 2.0 + floorf(hash2(tx + 7, ty + i * 9) * 4.0)
		_draw_safe(canvas, x, y, sx, sy, blade_x, 10.0, 2, blade_h, _c(block, "dark") * modulate)
	for i in 5:
		var top_x: float = 3.0 + floorf(hash2(tx + i * 7, ty + 2) * 24.0)
		var top_y: float = 2.0 + floorf(hash2(tx + 3, ty + i * 11) * 5.0)
		var top_color: Color = (_c(block, "dark") if i % 2 else Color("#a1c63a")) * modulate
		_draw_safe(canvas, x, y, sx, sy, top_x, top_y, 3, 2, top_color, 2.0)
	for i in 6:
		var soil_x: float = 3.0 + floorf(hash2(tx * 3 + i * 5, ty + 17) * 24.0)
		var soil_y: float = 16.0 + floorf(hash2(tx + 19, ty * 3 + i * 7) * 11.0)
		var soil_color: Color = (_c(BLOCKS.dirt, "light") if i % 3 == 0 else _c(BLOCKS.dirt, "dark")) * modulate
		_draw_safe(canvas, x, y, sx, sy, soil_x, soil_y, 3, 2, soil_color, 2.0)


func _draw_dirt(canvas: CanvasItem, tx: int, ty: int, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	canvas.draw_rect(Rect2(x, y, w, h), _c(block, "base") * modulate)
	for i in 9:
		var px: float = 3.0 + floorf(hash2(tx + i * 11, ty + 3) * 23.0)
		var py: float = 3.0 + floorf(hash2(tx + 7, ty + i * 13) * 23.0)
		var pw: float = 2.0 + float(i % 2)
		var tone: Color = (_c(block, "light") if i % 3 == 0 else (_c(block, "dark") if i % 3 == 1 else _c(block, "mid"))) * modulate
		_draw_safe(canvas, x, y, sx, sy, px, py, pw, 2, tone, 2.0)
	for i in 2:
		var clod_x: float = 6.0 + floorf(hash2(tx + i * 23, ty + 29) * 15.0)
		var clod_y: float = 7.0 + floorf(hash2(tx + 31, ty + i * 19) * 14.0)
		_draw_safe(canvas, x, y, sx, sy, clod_x, clod_y, 5, 4, _c(block, "dark") * modulate, 3.0)
		_draw_safe(canvas, x, y, sx, sy, clod_x + 1.0, clod_y, 3, 1, _c(block, "light") * modulate, 3.0)


func _draw_stone(canvas: CanvasItem, tx: int, ty: int, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color, cobble: bool) -> void:
	canvas.draw_rect(Rect2(x, y, w, h), _c(block, "base") * modulate)
	var patches: int = 5 if cobble else 6
	for i in patches:
		var pw: float = 5.0 + floorf(hash2(i + 7, tx + ty) * 4.0)
		var ph: float = 4.0 + floorf(hash2(tx + 3, i + ty) * 3.0)
		var px: float = 3.0 + floorf(hash2(tx + i * 17, ty + 5) * (23.0 - pw))
		var py: float = 3.0 + floorf(hash2(tx + 11, ty + i * 13) * (23.0 - ph))
		var patch: Color = (_c(block, "light") if i % 3 == 0 else _c(block, "dark")) * modulate
		_draw_safe(canvas, x, y, sx, sy, px, py, pw, ph, patch, 2.0)
		_draw_safe(canvas, x, y, sx, sy, px + 1.0, py, pw - 2.0, 1, Color(_c(block, "light"), 0.35 * modulate.a), 2.0)
	if cobble:
		for i in 4:
			var joint_x: float = 5.0 + float(i % 2) * 14.0
			var joint_y: float = 5.0 + float(int(i / 2)) * 14.0
			_draw_safe(canvas, x, y, sx, sy, joint_x, joint_y, 8, 7, _c(block, "mid") * modulate, 2.0)
			_draw_safe(canvas, x, y, sx, sy, joint_x + 1.0, joint_y + 1.0, 4, 2, _c(block, "light") * modulate, 2.0)


func _draw_wood(
	canvas: CanvasItem,
	tx: int,
	ty: int,
	x: float,
	y: float,
	w: float,
	h: float,
	sx: float,
	sy: float,
	block: Dictionary,
	modulate: Color,
	side_mask: int
) -> void:
	canvas.draw_rect(Rect2(x, y, w, h), _c(block, "base") * modulate)
	for i in 5:
		var grain_x: float = 5.0 + float(i * 5)
		var grain_y: float = 2.0 + floorf(hash2(tx + i * 7, ty + 3) * 6.0)
		var grain_h: float = 10.0 + floorf(hash2(tx + 9, ty + i * 11) * 12.0)
		_draw_safe(canvas, x, y, sx, sy, grain_x, grain_y, 1, grain_h, Color(_c(block, "light"), 0.3 * modulate.a), 2.0)
		_draw_safe(canvas, x, y, sx, sy, grain_x + 1.0, grain_y + grain_h - 4.0, 1, 4, Color(_c(block, "ring"), 0.7 * modulate.a), 2.0)
	for i in 2:
		var knot_x: float = 8.0 + floorf(hash2(tx + i * 19, ty + 7) * 12.0)
		var knot_y: float = 7.0 + floorf(hash2(tx + 5, ty + i * 23) * 13.0)
		_draw_safe(canvas, x, y, sx, sy, knot_x, knot_y, 5, 4, _c(block, "dark") * modulate, 3.0)
		_draw_safe(canvas, x, y, sx, sy, knot_x + 1.0, knot_y + 1.0, 2, 1, _c(block, "light") * modulate, 3.0)
	var bark_w: float = maxf(2.0 * sx, 1.0)
	if side_mask & BEVEL_LEFT:
		canvas.draw_rect(Rect2(x + sx, y, bark_w, h), _c(block, "dark") * modulate)
	if side_mask & BEVEL_RIGHT:
		canvas.draw_rect(Rect2(x + w - bark_w - sx, y, bark_w, h), _c(block, "dark") * modulate)


func _draw_leaves(canvas: CanvasItem, tx: int, ty: int, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	canvas.draw_rect(Rect2(x, y, w, h), _c(block, "base") * modulate)
	for i in 12:
		var leaf_x: float = 2.0 + floorf(hash2(tx + i * 7, ty + 2) * 25.0)
		var leaf_y: float = 2.0 + floorf(hash2(tx + 3, ty + i * 11) * 25.0)
		var leaf_color: Color = (_c(block, "light") if i % 4 == 0 else (_c(block, "dark") if i % 3 == 0 else _c(block, "mid"))) * modulate
		_draw_safe(canvas, x, y, sx, sy, leaf_x, leaf_y, 4, 3, leaf_color, 1.0)
	for i in 3:
		var hole_x: float = 5.0 + floorf(hash2(tx + i * 17, ty + 13) * 18.0)
		var hole_y: float = 5.0 + floorf(hash2(tx + 17, ty + i * 19) * 18.0)
		_draw_safe(canvas, x, y, sx, sy, hole_x, hole_y, 3, 3, Color(_c(block, "hole"), 0.55 * modulate.a), 2.0)
	if hash2(tx + 41, ty + 37) > 0.55:
		var berry_x: float = 7.0 + floorf(hash2(tx + 43, ty) * 16.0)
		var berry_y: float = 8.0 + floorf(hash2(tx, ty + 47) * 14.0)
		_draw_safe(canvas, x, y, sx, sy, berry_x, berry_y, 2, 2, Color("#d94a3d") * modulate, 2.0)


func _draw_obsidian(canvas: CanvasItem, tx: int, ty: int, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	canvas.draw_rect(Rect2(x, y, w, h), _c(block, "base") * modulate)
	for i in 3:
		var start_x: float = 6.0 + floorf(hash2(tx + i * 13, ty + 3) * 12.0)
		var start_y: float = 5.0 + float(i * 7)
		var vein: Color = Color(_c(block, "light"), (0.35 + float(i) * 0.08) * modulate.a)
		_draw_safe(canvas, x, y, sx, sy, start_x, start_y, 7, 2, vein, 2.0)
		_draw_safe(canvas, x, y, sx, sy, start_x + 5.0, start_y + 2.0, 2, 5, vein, 2.0)
	for i in 3:
		var spark_x: float = 5.0 + floorf(hash2(tx + i * 5, ty + 17) * 20.0)
		var spark_y: float = 5.0 + floorf(hash2(tx + 19, ty + i * 7) * 20.0)
		_draw_safe(canvas, x, y, sx, sy, spark_x, spark_y, 2, 2, Color(_c(block, "light"), 0.6 * modulate.a), 2.0)


func _draw_glass(canvas: CanvasItem, tx: int, ty: int, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	# A faint pane keeps the world visible through the block, while the inner
	# frame and deterministic glints make individual placed tiles readable.
	canvas.draw_rect(Rect2(x, y, w, h), Color(_c(block, "base"), 0.18 * modulate.a))
	var edge_x := maxf(2.0 * sx, 1.0)
	var edge_y := maxf(2.0 * sy, 1.0)
	var edge := Color(_c(block, "mid"), 0.72 * modulate.a)
	canvas.draw_rect(Rect2(x, y, w, edge_y), edge)
	canvas.draw_rect(Rect2(x, y + h - edge_y, w, edge_y), edge)
	canvas.draw_rect(Rect2(x, y, edge_x, h), edge)
	canvas.draw_rect(Rect2(x + w - edge_x, y, edge_x, h), edge)
	var glint_x := 5.0 + floorf(hash2(tx + 73, ty + 19) * 8.0)
	var glint_y := 5.0 + floorf(hash2(tx + 29, ty + 61) * 6.0)
	_draw_safe(canvas, x, y, sx, sy, glint_x, glint_y, 10, 2, Color(_c(block, "light"), 0.82 * modulate.a), 1.0)
	_draw_safe(canvas, x, y, sx, sy, glint_x, glint_y, 2, 8, Color(_c(block, "light"), 0.82 * modulate.a), 1.0)


func _draw_chest(canvas: CanvasItem, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	canvas.draw_rect(Rect2(x, y + h * 0.22, w, h * 0.78), _c(block, "base") * modulate)
	canvas.draw_rect(Rect2(x, y + h * 0.22, w, h * 0.16), _c(block, "light") * modulate)
	canvas.draw_rect(Rect2(x, y + h * 0.42, w, maxf(2.0 * sy, 1.0)), _c(block, "dark") * modulate)
	canvas.draw_rect(Rect2(x + w * 0.42, y + h * 0.35, w * 0.16, h * 0.25), Color("#e7bd55") * modulate)
	canvas.draw_rect(Rect2(x + w * 0.46, y + h * 0.39, w * 0.08, h * 0.12), Color("#6f531e") * modulate)
	canvas.draw_rect(Rect2(x, y + h - maxf(3.0 * sy, 1.0), w, maxf(3.0 * sy, 1.0)), _c(block, "dark") * modulate)


func _draw_aged_chest(canvas: CanvasItem, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	_draw_chest(canvas, x, y, w, h, sx, sy, block, modulate)
	var scratch := Color(_c(block, "dark"), 0.82 * modulate.a)
	var worn := Color("#6f5231", 0.92 * modulate.a)
	# Three asymmetrical cuts and one missing corner distinguish it from a normal
	# chest while keeping the same brown silhouette at a glance.
	canvas.draw_line(Vector2(x + w * 0.18, y + h * 0.48), Vector2(x + w * 0.34, y + h * 0.61), scratch, maxf(1.5 * minf(sx, sy), 1.0))
	canvas.draw_line(Vector2(x + w * 0.22, y + h * 0.64), Vector2(x + w * 0.38, y + h * 0.54), scratch, maxf(1.2 * minf(sx, sy), 1.0))
	canvas.draw_line(Vector2(x + w * 0.68, y + h * 0.52), Vector2(x + w * 0.82, y + h * 0.68), scratch, maxf(1.2 * minf(sx, sy), 1.0))
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(x + w, y + h * 0.22),
		Vector2(x + w * 0.84, y + h * 0.22),
		Vector2(x + w, y + h * 0.39),
	]), worn)
	# The slightly dropped latch sells age without turning the chest into a new
	# magical object.
	canvas.draw_rect(Rect2(x + w * 0.43, y + h * 0.39, w * 0.16, h * 0.22), Color("#b9913f") * modulate)


func _draw_death_cache(canvas: CanvasItem, x: float, y: float, w: float, h: float, sx: float, sy: float, modulate: Color, anim_frame: int) -> void:
	var spectral := {
		"base": "#315b6c",
		"mid": "#47798a",
		"dark": "#142f3b",
		"light": "#83d5e5",
	}
	_draw_chest(canvas, x, y, w, h, sx, sy, spectral, modulate)
	var pulse := 0.62 + sin(float(anim_frame) * 0.12) * 0.16
	var glow := Color("#9cecff", pulse * modulate.a)
	var core := Color("#e2fbff", (pulse + 0.12) * modulate.a)
	# Replace the ordinary brass latch with a cold soul-rune.
	canvas.draw_rect(Rect2(x + w * 0.40, y + h * 0.34, w * 0.20, h * 0.28), Color("#183d4a") * modulate)
	var rune_center := Vector2(x + w * 0.5, y + h * 0.47)
	var rune_radius := maxf(3.0 * minf(sx, sy), 2.0)
	canvas.draw_colored_polygon(PackedVector2Array([
		rune_center + Vector2(0, -rune_radius),
		rune_center + Vector2(rune_radius, 0),
		rune_center + Vector2(0, rune_radius),
		rune_center + Vector2(-rune_radius, 0),
	]), glow)
	canvas.draw_rect(Rect2(rune_center - Vector2.ONE * minf(sx, sy), Vector2.ONE * maxf(2.0 * minf(sx, sy), 1.0)), core)
	# Two small wisps make the cache readable even when its latch is occluded.
	for index in 2:
		var phase := float(anim_frame) * 0.08 + float(index) * 2.4
		var wisp_x := x + w * (0.29 + float(index) * 0.42) + sin(phase) * 1.4 * sx
		var wisp_y := y + h * 0.19 + cos(phase * 0.8) * 1.2 * sy
		canvas.draw_circle(Vector2(wisp_x, wisp_y), maxf(1.5 * minf(sx, sy), 1.0), glow)
		canvas.draw_line(Vector2(wisp_x, wisp_y + sy), Vector2(wisp_x - 2.0 * sx, wisp_y + 4.0 * sy), Color(glow, glow.a * 0.55), maxf(sx, 1.0))


func _draw_workbench(canvas: CanvasItem, x: float, y: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	var base := _c(block, "base") * modulate
	var mid := _c(block, "mid") * modulate
	var dark := _c(block, "dark") * modulate
	var light := _c(block, "light") * modulate
	var metal := Color("#87909a") * modulate
	var metal_light := Color("#c3ccd2") * modulate
	# A thick, bright work surface gives the station a strong silhouette at
	# world scale. The board divisions remain readable in the hotbar preview.
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 0, 0, TILE, TILE), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 1, 1, 30, 7), mid)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 1, 1, 30, 2), light)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 1, 7, 30, 3), base)
	for seam_x in [10, 21]:
		canvas.draw_rect(_tile_rect(x, y, sx, sy, seam_x, 2, 1, 5), dark)
	# Framed front with a recessed cabinet instead of an undifferentiated cube.
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 3, 10, 26, 20), base)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 5, 12, 22, 15), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 8, 14, 16, 11), mid.darkened(0.16))
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 3, 27, 7, 4), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 22, 27, 7, 4), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 5, 11, 2, 15), light.darkened(0.2))
	# Crossed hammer and chisel identify the block as a crafting station even
	# when it is rendered as a small inventory icon.
	canvas.draw_line(
		Vector2(x + 10.0 * sx, y + 23.0 * sy),
		Vector2(x + 20.0 * sx, y + 14.0 * sy),
		metal,
		maxf(2.0 * minf(sx, sy), 1.0),
	)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 17, 12, 8, 4), metal_light)
	canvas.draw_line(
		Vector2(x + 11.0 * sx, y + 14.0 * sy),
		Vector2(x + 21.0 * sx, y + 23.0 * sy),
		light,
		maxf(2.0 * minf(sx, sy), 1.0),
	)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 8, 12, 6, 3), light.lightened(0.08))


func _draw_furnace(canvas: CanvasItem, x: float, y: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	var base := _c(block, "base") * modulate
	var mid := _c(block, "mid") * modulate
	var dark := _c(block, "dark") * modulate
	var light := _c(block, "light") * modulate
	var fire_dark := Color("#702718") * modulate
	var fire := Color("#e45b24") * modulate
	var ember := Color("#ffd166") * modulate
	# Chunky masonry and alternating joints keep the station distinct from the
	# natural stone texture at both world and inventory-icon sizes.
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 0, 0, TILE, TILE), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 1, 1, 30, 30), base)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 1, 1, 30, 3), light)
	for mortar_y in [9, 18, 27]:
		canvas.draw_rect(_tile_rect(x, y, sx, sy, 1, mortar_y, 30, 2), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 10, 3, 2, 7), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 22, 3, 2, 7), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 5, 19, 2, 9), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 25, 19, 2, 9), dark)
	# Stepped arch and deep opening form a clear furnace face without relying on
	# antialiasing, which would become muddy under nearest-neighbor scaling.
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 9, 10, 14, 3), mid)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 7, 13, 18, 14), mid)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 10, 13, 12, 3), dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 9, 16, 14, 10), Color("#17171b") * modulate)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 9, 23, 14, 3), fire_dark)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 11, 22, 4, 3), fire)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 17, 21, 4, 4), fire)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 12, 22, 2, 2), ember)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 18, 21, 2, 2), ember)
	canvas.draw_rect(_tile_rect(x, y, sx, sy, 3, 29, 26, 2), mid)


func _draw_generated(canvas: CanvasItem, tx: int, ty: int, x: float, y: float, w: float, h: float, sx: float, sy: float, block: Dictionary, modulate: Color) -> void:
	var base := _c(block, "base") * modulate
	var mid := _c(block, "mid") * modulate
	var dark := _c(block, "dark") * modulate
	var light := _c(block, "light") * modulate
	var seed := int(block.get("visual_seed", 1))
	canvas.draw_rect(Rect2(x, y, w, h), base)
	match str(block.get("pattern", "grain")):
		"layers":
			for i in 4:
				var band_y := 5.0 + float(i) * 7.0 + floorf(hash2(seed + tx + i, ty) * 2.0)
				var band_color := light if i % 2 == 0 else dark
				_draw_safe(canvas, x, y, sx, sy, 2.0, band_y, 28.0, 2.0, Color(band_color, 0.55 * modulate.a), 1.0)
				var cut_x := 4.0 + floorf(hash2(seed + tx * 3, ty + i * 11) * 18.0)
				_draw_safe(canvas, x, y, sx, sy, cut_x, band_y, 7.0, 2.0, mid, 1.0)
		"veins":
			for i in 3:
				var start := Vector2(
					x + (4.0 + hash2(seed + tx + i * 17, ty) * 10.0) * sx,
					y + (4.0 + float(i) * 8.0) * sy
				)
				var bend := start + Vector2((7.0 + float(i)) * sx, (3.0 if i % 2 == 0 else -3.0) * sy)
				var finish := bend + Vector2(10.0 * sx, 5.0 * sy)
				canvas.draw_polyline(PackedVector2Array([start, bend, finish]), Color(light, 0.72 * modulate.a), maxf(1.5 * sx, 1.0))
		"crystals":
			for i in 4:
				var cx := 6.0 + floorf(hash2(seed + tx + i * 19, ty + 7) * 19.0)
				var cy := 7.0 + floorf(hash2(seed + tx + 5, ty + i * 13) * 17.0)
				var crystal := PackedVector2Array([
					Vector2(x + cx * sx, y + (cy - 4.0) * sy),
					Vector2(x + (cx + 3.0) * sx, y + cy * sy),
					Vector2(x + cx * sx, y + (cy + 4.0) * sy),
					Vector2(x + (cx - 3.0) * sx, y + cy * sy),
				])
				canvas.draw_colored_polygon(crystal, light if i % 2 == 0 else mid)
		"organic":
			for i in 9:
				var blob_x := 3.0 + floorf(hash2(seed + tx + i * 7, ty + 3) * 24.0)
				var blob_y := 3.0 + floorf(hash2(seed + tx + 11, ty + i * 9) * 24.0)
				var radius := (1.5 + float(i % 3)) * minf(sx, sy)
				canvas.draw_circle(Vector2(x + blob_x * sx, y + blob_y * sy), radius, light if i % 3 == 0 else mid)
			for i in 3:
				var pore_x := 7.0 + floorf(hash2(seed + tx + i * 23, ty + 17) * 16.0)
				var pore_y := 7.0 + floorf(hash2(seed + tx + 29, ty + i * 17) * 16.0)
				canvas.draw_circle(Vector2(x + pore_x * sx, y + pore_y * sy), 1.5 * minf(sx, sy), dark)
		"cracks":
			for i in 4:
				var crack_start := Vector2(
					x + (4.0 + hash2(seed + tx + i * 17, ty + 31) * 23.0) * sx,
					y + (3.0 + hash2(seed + tx + 37, ty + i * 19) * 9.0) * sy
				)
				var crack_mid := crack_start + Vector2((-3.0 + hash2(seed + i, tx + ty) * 7.0) * sx, 7.0 * sy)
				var crack_end := crack_mid + Vector2((2.0 + hash2(seed + i * 5, ty) * 5.0) * sx, 8.0 * sy)
				canvas.draw_polyline(PackedVector2Array([crack_start, crack_mid, crack_end]), Color(dark, 0.82 * modulate.a), maxf(sx, 1.0))
		"bubbles":
			for i in 8:
				var bubble_x := 5.0 + floorf(hash2(seed + tx + i * 13, ty + 3) * 21.0)
				var bubble_y := 5.0 + floorf(hash2(seed + tx + 9, ty + i * 17) * 21.0)
				var bubble_r := (1.5 + float(i % 3)) * minf(sx, sy)
				var bubble_center := Vector2(x + bubble_x * sx, y + bubble_y * sy)
				canvas.draw_circle(bubble_center, bubble_r, Color(mid, 0.55 * modulate.a))
				canvas.draw_arc(bubble_center, bubble_r, 0.0, TAU, 16, Color(light, 0.75 * modulate.a), maxf(sx, 1.0))
		"scales":
			for row in 4:
				for col in 5:
					var scale_x := 4.0 + float(col) * 6.0 + (3.0 if row % 2 else 0.0)
					var scale_y := 4.0 + float(row) * 7.0
					var scale_center := Vector2(x + scale_x * sx, y + scale_y * sy)
					canvas.draw_arc(scale_center, 3.5 * minf(sx, sy), 0.05, PI - 0.05, 10, Color(light if (row + col) % 3 == 0 else mid, 0.7 * modulate.a), maxf(sx, 1.0))
		"cells":
			for row in 4:
				for col in 4:
					var cell_x := 3.0 + float(col) * 7.0 + (3.0 if row % 2 else 0.0)
					var cell_y := 3.0 + float(row) * 7.0
					_draw_safe(canvas, x, y, sx, sy, cell_x, cell_y, 6.0, 6.0, Color(mid, 0.75 * modulate.a), 1.0)
					_draw_safe(canvas, x, y, sx, sy, cell_x + 1.0, cell_y + 1.0, 4.0, 4.0, base, 1.0)
		"metal":
			canvas.draw_rect(_tile_rect(x, y, sx, sy, 0, 9, TILE, 3), Color(dark, 0.6 * modulate.a))
			canvas.draw_rect(_tile_rect(x, y, sx, sy, 0, 21, TILE, 2), Color(light, 0.4 * modulate.a))
			for i in 4:
				var rivet_x := 5.0 + float(i % 2) * 22.0
				var rivet_y := 5.0 + float(int(i / 2)) * 22.0
				canvas.draw_circle(Vector2(x + rivet_x * sx, y + rivet_y * sy), 1.5 * minf(sx, sy), light)
				canvas.draw_circle(Vector2(x + rivet_x * sx, y + rivet_y * sy), 0.6 * minf(sx, sy), dark)
		"runes":
			for i in 3:
				var rune_x := 6.0 + float(i) * 9.0
				var rune_y := 8.0 + floorf(hash2(seed + tx + i, ty) * 12.0)
				var rune_color := Color(light, (0.62 + 0.12 * sin(float(Engine.get_process_frames()) * 0.06 + float(i))) * modulate.a)
				var rune_points := PackedVector2Array([
					Vector2(x + rune_x * sx, y + (rune_y + 7.0) * sy),
					Vector2(x + (rune_x + 3.0) * sx, y + rune_y * sy),
					Vector2(x + (rune_x + 6.0) * sx, y + (rune_y + 7.0) * sy),
					Vector2(x + (rune_x + 3.0) * sx, y + (rune_y + 4.0) * sy),
				])
				canvas.draw_polyline(rune_points, rune_color, maxf(1.3 * sx, 1.0))
		"stripes":
			for i in 7:
				var stripe_x := -6.0 + float(i) * 7.0 + floorf(hash2(seed + tx + i, ty) * 2.0)
				var stripe_width := maxf(2.0 * sx, 1.0)
				# Clip the diagonal analytically to the tile. CanvasItem drawing is not
				# clipped per block, so negative stripe starts used to protrude into air.
				var inset_x := stripe_width * 0.5 / maxf(sx, 0.001)
				var inset_y := stripe_width * 0.5 / maxf(sy, 0.001)
				var t0 := maxf(inset_y / float(TILE), (inset_x - stripe_x) / 15.0)
				var t1 := minf((float(TILE) - inset_y) / float(TILE), (float(TILE) - inset_x - stripe_x) / 15.0)
				if t0 <= t1:
					var stripe_points := PackedVector2Array([
						Vector2(x + (stripe_x + 15.0 * t0) * sx, y + h * t0),
						Vector2(x + (stripe_x + 15.0 * t1) * sx, y + h * t1),
					])
					canvas.draw_polyline(stripe_points, Color(light if i % 2 == 0 else dark, 0.45 * modulate.a), stripe_width)
		_:
			for i in 12:
				var grain_x := 3.0 + floorf(hash2(seed + tx + i * 11, ty + 5) * 24.0)
				var grain_y := 3.0 + floorf(hash2(seed + tx + 7, ty + i * 13) * 24.0)
				var grain_color := light if i % 4 == 0 else (dark if i % 3 == 0 else mid)
				_draw_safe(canvas, x, y, sx, sy, grain_x, grain_y, 3.0 + float(i % 2), 2.0, grain_color, 1.0)


func _draw_fluid(
	canvas: CanvasItem,
	tx: int,
	ty: int,
	x: float,
	y: float,
	w: float,
	h: float,
	sx: float,
	sy: float,
	block: Dictionary,
	modulate: Color,
	anim_frame: int,
	fluid_level: int,
	fluid_falling: bool,
	open_above: bool
) -> void:
	var name: String = block.get("name", "water")
	var depth_factor := 1.0 if fluid_falling or fluid_level == 0 else maxf(0.35, 1.0 - float(fluid_level) / float(MAX_FLUID_LEVEL))
	var alpha: float = (0.78 if name == "water" else 0.9) * modulate.a
	var body: Color = _c(block, "base")
	body.a = alpha
	canvas.draw_rect(Rect2(x, y, w, h), body)
	var shade: Color = _c(block, "deep")
	shade.a = 0.22 * modulate.a
	canvas.draw_rect(Rect2(x, y + h * 0.55, w, h * 0.45), shade)
	if open_above:
		var surface_off: float = floorf(h * (1.0 - depth_factor))
		var surface: Color = _c(block, "light")
		surface.a = 0.55 * modulate.a
		canvas.draw_rect(Rect2(x, y + surface_off, w, 4.0 * sy), surface)
		for i in 2:
			var wave_x: float = 4.0 + float(i * 12) + sin(float(anim_frame) * 0.06 + float(tx + i)) * 1.5
			_draw_safe(
				canvas, x, y, sx, sy,
				wave_x, surface_off / sy + 1.0, 6, 1,
				Color(_c(block, "light"), 0.45 * modulate.a),
				2.0
			)
	else:
		for i in 2:
			var speck_x: float = 5.0 + floorf(hash2(tx + i * 9, ty + 4) * 18.0)
			var speck_y: float = 8.0 + floorf(hash2(tx + 5, ty + i * 11) * 14.0)
			_draw_safe(
				canvas, x, y, sx, sy,
				speck_x, speck_y, 3, 2,
				Color(_c(block, "light"), 0.22 * modulate.a),
				2.0
			)
	if name == "lava":
		var pulse: float = 0.4 + sin(float(anim_frame) * 0.12 + float(tx + ty)) * 0.12
		for i in 2:
			var glow_x: float = 6.0 + floorf(hash2(tx + i * 17, ty + 5) * 16.0)
			var glow_y: float = 10.0 + floorf(hash2(tx + 7, ty + i * 13) * 12.0)
			_draw_safe(canvas, x, y, sx, sy, glow_x, glow_y, 4, 2, Color("#fef08a", pulse * modulate.a), 2.0)


func draw_hotbar_icon(canvas: CanvasItem, origin: Vector2, size: float, block_name: String, anim_frame: int = 0) -> void:
	var block: Dictionary = BLOCKS.get(block_name, BLOCKS.stone).duplicate()
	block["name"] = block_name
	var seed: int = int(block.get("id", 1))
	draw_block(
		canvas,
		seed * 17,
		seed * 13,
		block,
		Color.WHITE,
		anim_frame,
		0,
		false,
		true,
		Rect2(origin.x, origin.y, size, size)
	)


func _c(block: Dictionary, key: String, fallback: String = "#888888") -> Color:
	return Color(block.get(key, fallback))


const PLANT_CONNECT_UP := 1
const PLANT_CONNECT_DOWN := 2
const PLANT_CONNECT_LEFT := 4
const PLANT_CONNECT_RIGHT := 8


func plant_connection_mask(cells: Array, pos: Vector2i) -> int:
	var mask := 0
	if pos + Vector2i.UP in cells:
		mask |= PLANT_CONNECT_UP
	if pos + Vector2i.DOWN in cells:
		mask |= PLANT_CONNECT_DOWN
	if pos + Vector2i.LEFT in cells:
		mask |= PLANT_CONNECT_LEFT
	if pos + Vector2i.RIGHT in cells:
		mask |= PLANT_CONNECT_RIGHT
	return mask


func _draw_decorative_plant(canvas: CanvasItem, dest: Rect2, shape: String, stem: Color, accent: Color, detail: Color, dark: Color, world_cell: bool) -> void:
	var x := dest.position.x
	var y := dest.position.y
	var w := dest.size.x
	var h := dest.size.y
	var unit := maxf(1.0, floorf(w / 12.0))
	var center_x := x + w * 0.5
	# World plants occupy the air cell directly above their substrate, so their
	# main stem must end at the cell boundary. Keep a little preview padding only
	# for inventory icons.
	var ground_y := y + h * (1.0 if world_cell else 0.9)
	var stem_width := unit * 2.0
	match shape:
		"branch_bloom":
			canvas.draw_rect(Rect2(center_x - stem_width * 0.5, y + h * 0.36, stem_width, ground_y - (y + h * 0.36)), stem)
			canvas.draw_rect(Rect2(x + w * 0.25, y + h * 0.56, w * 0.5, stem_width), stem)
			canvas.draw_rect(Rect2(x + w * 0.27, y + h * 0.33, stem_width, h * 0.25), stem)
			canvas.draw_rect(Rect2(x + w * 0.68, y + h * 0.46, stem_width, h * 0.12), stem)
			canvas.draw_rect(Rect2(x + w * 0.19, y + h * 0.25, w * 0.24, h * 0.18), detail)
			canvas.draw_rect(Rect2(x + w * 0.62, y + h * 0.35, w * 0.22, h * 0.16), accent)
		"cross_bloom":
			canvas.draw_rect(Rect2(center_x - stem_width * 0.5, y + h * 0.43, stem_width, ground_y - (y + h * 0.43)), stem)
			canvas.draw_rect(Rect2(x + w * 0.18, y + h * 0.62, w * 0.64, stem_width), stem.lightened(0.08))
			canvas.draw_rect(Rect2(x + w * 0.17, y + h * 0.58, w * 0.2, h * 0.13), accent)
			canvas.draw_rect(Rect2(x + w * 0.63, y + h * 0.58, w * 0.2, h * 0.13), accent)
			canvas.draw_rect(Rect2(x + w * 0.34, y + h * 0.18, w * 0.32, h * 0.26), detail)
			canvas.draw_rect(Rect2(x + w * 0.43, y + h * 0.25, w * 0.14, h * 0.12), dark.lightened(0.35))
		"bell_cluster":
			canvas.draw_rect(Rect2(center_x - stem_width * 0.5, y + h * 0.38, stem_width, ground_y - (y + h * 0.38)), stem)
			for i in 3:
				var flower_x := x + w * (0.29 + float(i) * 0.21)
				var flower_y := y + h * (0.34 if i == 1 else 0.46)
				canvas.draw_line(Vector2(center_x, ground_y - h * 0.22), Vector2(flower_x, flower_y), stem, unit)
				canvas.draw_circle(Vector2(flower_x, flower_y), w * 0.11, detail if i == 1 else accent)
				canvas.draw_circle(Vector2(flower_x, flower_y), w * 0.04, detail.lightened(0.3))
		_:
			canvas.draw_rect(Rect2(center_x - stem_width * 0.5, y + h * 0.4, stem_width, ground_y - (y + h * 0.4)), stem)
			canvas.draw_rect(Rect2(x + w * 0.24, y + h * 0.58, w * 0.22, h * 0.13), accent)
			canvas.draw_rect(Rect2(x + w * 0.54, y + h * 0.51, w * 0.22, h * 0.13), accent)
			canvas.draw_rect(Rect2(x + w * 0.31, y + h * 0.16, w * 0.38, h * 0.29), detail)
			canvas.draw_rect(Rect2(x + w * 0.43, y + h * 0.25, w * 0.14, h * 0.11), detail.lightened(0.35))


func _draw_potted_plant(canvas: CanvasItem, dest: Rect2, block: Dictionary, shape: String, cell_index: int, connection_mask: int, world_cell: bool) -> void:
	var stem := _c(block, "base", "#2b7d3b")
	var accent := _c(block, "light", "#9adf45")
	var dark := _c(block, "dark", "#185029")
	var pot := _c(block, "detail", "#c66a32")
	var x := dest.position.x
	var y := dest.position.y
	var w := dest.size.x
	var h := dest.size.y
	var unit := maxf(1.0, floorf(w / 12.0))
	var center_x := x + w * 0.5
	var preview := not world_cell
	var base_cell := preview or cell_index == 0
	if base_cell:
		canvas.draw_rect(Rect2(x + w * 0.24, y + h * 0.67, w * 0.52, h * 0.12), pot.lightened(0.12))
		canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(x + w * 0.29, y + h * 0.78), Vector2(x + w * 0.71, y + h * 0.78),
			Vector2(x + w * 0.64, y + h * 0.94), Vector2(x + w * 0.36, y + h * 0.94)
		]), pot)
		canvas.draw_rect(Rect2(x + w * 0.37, y + h * 0.8, w * 0.26, unit), pot.lightened(0.25))
		var top_y := y - unit if world_cell and bool(connection_mask & PLANT_CONNECT_UP) else y + h * 0.3
		canvas.draw_rect(Rect2(center_x - unit, top_y, unit * 2.0, y + h * 0.69 - top_y), stem)
		if preview or not bool(connection_mask & PLANT_CONNECT_UP):
			canvas.draw_circle(Vector2(center_x - w * 0.16, y + h * 0.34), w * 0.16, accent)
			canvas.draw_circle(Vector2(center_x + w * 0.14, y + h * 0.28), w * 0.18, stem.lightened(0.13))
			canvas.draw_circle(Vector2(center_x, y + h * 0.18), w * 0.13, accent.lightened(0.12))
		return
	canvas.draw_rect(Rect2(center_x - unit, y - unit, unit * 2.0, h + unit * 2.0), stem)
	if shape == "tall_planter":
		canvas.draw_rect(Rect2(x + w * 0.22, y + h * 0.36, w * 0.28, h * 0.14), accent)
		canvas.draw_rect(Rect2(x + w * 0.5, y + h * 0.19, w * 0.27, h * 0.14), stem.lightened(0.18))
		canvas.draw_rect(Rect2(x + w * 0.29, y + h * 0.06, w * 0.25, h * 0.14), accent.lightened(0.08))
	else:
		canvas.draw_circle(Vector2(center_x - w * 0.18, y + h * 0.38), w * 0.18, accent)
		canvas.draw_circle(Vector2(center_x + w * 0.18, y + h * 0.3), w * 0.19, stem.lightened(0.15))
		canvas.draw_circle(Vector2(center_x, y + h * 0.12), w * 0.17, accent.lightened(0.08))
	canvas.draw_rect(Rect2(center_x - unit * 0.5, y + h * 0.08, unit, h * 0.12), dark.lightened(0.2))


func _draw_hanging_vines(canvas: CanvasItem, dest: Rect2, stem: Color, accent: Color, detail: Color, cell_index: int, connection_mask: int, world_cell: bool) -> void:
	var x := dest.position.x
	var y := dest.position.y
	var w := dest.size.x
	var h := dest.size.y
	var unit := maxf(1.0, floorf(w / 12.0))
	var connects_down := world_cell and bool(connection_mask & PLANT_CONNECT_DOWN)
	var strand_xs := [0.27, 0.5, 0.73]
	for strand_index in strand_xs.size():
		var strand_x: float = x + w * float(strand_xs[strand_index])
		var wave := float((cell_index + strand_index) % 2) * unit
		var top_y := y - unit
		var bottom_y := y + h + unit if connects_down else y + h * (0.68 + float(strand_index) * 0.08)
		canvas.draw_rect(Rect2(strand_x - unit + wave, top_y, unit * 2.0, bottom_y - top_y), stem if strand_index != 1 else stem.lightened(0.08))
		for leaf_index in 3:
			var leaf_y := y + h * (0.18 + float(leaf_index) * 0.24) + float((strand_index + cell_index) % 2) * unit
			if leaf_y > bottom_y - unit:
				continue
			var side := -1.0 if (leaf_index + strand_index + cell_index) % 2 == 0 else 1.0
			var leaf_color := accent if (leaf_index + strand_index) % 3 != 0 else detail
			var leaf_width := w * 0.16
			var leaf_x := strand_x + wave - leaf_width if side < 0.0 else strand_x + wave + unit
			canvas.draw_rect(Rect2(leaf_x, leaf_y, leaf_width, h * 0.12), leaf_color)
		if not connects_down:
			canvas.draw_circle(Vector2(strand_x + wave, bottom_y), w * 0.08, accent.lightened(0.08))
	if not world_cell:
		canvas.draw_rect(Rect2(x + w * 0.17, y + h * 0.05, w * 0.66, h * 0.09), stem.darkened(0.2))


func draw_plant_cell(canvas: CanvasItem, dest: Rect2, block: Dictionary, stage: int = 1, cell_index: int = 0, connection_mask: int = 0, world_cell: bool = false, traits: Dictionary = {}) -> void:
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
	var form := str(growth.get("form", "vertical_up"))
	var hybrid_palette: Array = traits.get("palette", []) if traits.get("palette", []) is Array else []
	var stem := Color(str(hybrid_palette[0])) if hybrid_palette.size() > 0 and Color.html_is_valid(str(hybrid_palette[0])) else _c(block, "base", "#2b7d3b")
	var accent := Color(str(hybrid_palette[1])) if hybrid_palette.size() > 1 and Color.html_is_valid(str(hybrid_palette[1])) else _c(block, "light", "#9adf45")
	var dark := Color(str(hybrid_palette[2])) if hybrid_palette.size() > 2 and Color.html_is_valid(str(hybrid_palette[2])) else _c(block, "dark", "#185029")
	var detail := Color(str(hybrid_palette[3])) if hybrid_palette.size() > 3 and Color.html_is_valid(str(hybrid_palette[3])) else _c(block, "detail", "#e67e36")
	var x := dest.position.x
	var y := dest.position.y
	var w := dest.size.x
	var h := dest.size.y
	var thickness := maxf(2.0, w * 0.13)
	var canopy := str(traits.get("canopy_shape", visual.get("canopy_shape", "tuft")))
	var plant_pattern := str(traits.get("pattern", visual.get("pattern", "organic")))
	if form == "decorative":
		_draw_decorative_plant(canvas, dest, canopy, stem, accent, detail, dark, world_cell)
		_draw_plant_pattern_overlay(canvas, dest, plant_pattern, detail, dark)
		return
	if form == "potted":
		_draw_potted_plant(canvas, dest, block, canopy, cell_index, connection_mask, world_cell)
		_draw_plant_pattern_overlay(canvas, dest, plant_pattern, detail, dark)
		return
	if form == "hanging" and canopy == "hanging_vines":
		_draw_hanging_vines(canvas, dest, stem, accent, detail, cell_index, connection_mask, world_cell)
		_draw_plant_pattern_overlay(canvas, dest, plant_pattern, detail, dark)
		return
	if form == "surface_creeper":
		if not world_cell:
			canvas.draw_rect(Rect2(x + w * 0.08, y + h * 0.62, w * 0.84, thickness), stem)
			for i in 3:
				var px := x + w * (0.2 + float(i) * 0.28)
				canvas.draw_circle(Vector2(px, y + h * (0.48 if i % 2 == 0 else 0.72)), w * 0.12, accent if i == cell_index % 3 else stem.lightened(0.12))
			_draw_plant_pattern_overlay(canvas, dest, plant_pattern, detail, dark)
			return
		var anchor_side := str(traits.get("surface_anchor", "left"))
		var edge_depth := w * 0.24
		var patch_size := maxf(2.0, w * 0.11)
		if anchor_side in ["left", "right"]:
			var edge_x := x + thickness * 0.35 if anchor_side == "left" else x + w - thickness * 1.35
			var direction := 1.0 if anchor_side == "left" else -1.0
			canvas.draw_rect(Rect2(edge_x, y, thickness, h), Color(stem, 0.88))
			for i in 4:
				var patch_y := y + h * (0.12 + float(i) * 0.23)
				var depth := edge_depth * (0.55 + float((i + cell_index) % 3) * 0.2)
				var patch_x := edge_x if direction > 0.0 else edge_x - depth + thickness
				canvas.draw_rect(Rect2(patch_x, patch_y, depth, patch_size), accent if i % 2 == 0 else stem.lightened(0.12))
				canvas.draw_rect(Rect2(edge_x + direction * depth * 0.45, patch_y - patch_size * 0.45, patch_size, patch_size), detail if i == cell_index % 4 else dark.lightened(0.2))
		else:
			var edge_y := y + thickness * 0.35 if anchor_side == "ceiling" else y + h - thickness * 1.35
			var direction := 1.0 if anchor_side == "ceiling" else -1.0
			canvas.draw_rect(Rect2(x, edge_y, w, thickness), Color(stem, 0.88))
			for i in 4:
				var patch_x := x + w * (0.12 + float(i) * 0.23)
				var depth := edge_depth * (0.55 + float((i + cell_index) % 3) * 0.2)
				var patch_y := edge_y if direction > 0.0 else edge_y - depth + thickness
				canvas.draw_rect(Rect2(patch_x, patch_y, patch_size, depth), accent if i % 2 == 0 else stem.lightened(0.12))
				canvas.draw_rect(Rect2(patch_x - patch_size * 0.45, edge_y + direction * depth * 0.45, patch_size, patch_size), detail if i == cell_index % 4 else dark.lightened(0.2))
		return
	var down := form == "vertical_down" or form == "hanging"
	var center_x := x + w * 0.5
	if world_cell:
		var connects_up := bool(connection_mask & PLANT_CONNECT_UP)
		var connects_down := bool(connection_mask & PLANT_CONNECT_DOWN)
		var grows_up := form == "vertical_up" or form == "bidirectional_vertical"
		var grows_down := down or form == "bidirectional_vertical"
		var top_tip := grows_up and not connects_up
		var bottom_tip := grows_down and not connects_down
		var top_y := y + h * 0.22 if top_tip else y - 1.0
		var bottom_y := y + h * 0.78 if bottom_tip else y + h + 1.0
		if form == "vertical_up" and cell_index == 0:
			bottom_y = y + h + 1.0
		elif down and cell_index == 0:
			top_y = y - 1.0
		canvas.draw_rect(Rect2(center_x - thickness * 0.5, top_y, thickness, maxf(thickness, bottom_y - top_y)), stem)
		var world_bulbs: Array[float] = []
		if top_tip:
			world_bulbs.append(top_y)
		if bottom_tip:
			world_bulbs.append(bottom_y)
		var world_canopy := canopy
		var world_radius := w * clampf(0.18 + float(stage) * 0.025, 0.18, 0.34)
		for world_bulb_y in world_bulbs:
			if world_canopy == "crystal":
				canvas.draw_colored_polygon(PackedVector2Array([Vector2(center_x, world_bulb_y - world_radius), Vector2(center_x + world_radius, world_bulb_y), Vector2(center_x, world_bulb_y + world_radius), Vector2(center_x - world_radius, world_bulb_y)]), accent)
			elif world_canopy == "bulb":
				canvas.draw_circle(Vector2(center_x, world_bulb_y), world_radius, accent)
				canvas.draw_circle(Vector2(center_x - world_radius * 0.25, world_bulb_y - world_radius * 0.25), world_radius * 0.28, accent.lightened(0.28))
			else:
				canvas.draw_circle(Vector2(center_x, world_bulb_y), world_radius * 0.7, accent)
				canvas.draw_circle(Vector2(center_x - world_radius * 0.65, world_bulb_y + world_radius * 0.1), world_radius * 0.58, stem.lightened(0.15))
				canvas.draw_circle(Vector2(center_x + world_radius * 0.65, world_bulb_y + world_radius * 0.1), world_radius * 0.58, dark.lightened(0.2))
		_draw_plant_pattern_overlay(canvas, dest, plant_pattern, detail, dark)
		return
	var start_y := y + h * (0.15 if down else 0.88)
	var end_y := y + h * (0.85 if down else 0.18)
	canvas.draw_line(Vector2(center_x, start_y), Vector2(center_x, end_y), stem, thickness)
	var bulb_y := end_y
	var radius := w * clampf(0.18 + float(stage) * 0.025, 0.18, 0.34)
	if canopy == "crystal":
		canvas.draw_colored_polygon(PackedVector2Array([Vector2(center_x, bulb_y - radius), Vector2(center_x + radius, bulb_y), Vector2(center_x, bulb_y + radius), Vector2(center_x - radius, bulb_y)]), accent)
	elif canopy == "bulb":
		canvas.draw_circle(Vector2(center_x, bulb_y), radius, accent)
		canvas.draw_circle(Vector2(center_x - radius * 0.25, bulb_y - radius * 0.25), radius * 0.28, accent.lightened(0.28))
	else:
		canvas.draw_circle(Vector2(center_x, bulb_y), radius * 0.7, accent)
		canvas.draw_circle(Vector2(center_x - radius * 0.65, bulb_y + radius * 0.1), radius * 0.58, stem.lightened(0.15))
		canvas.draw_circle(Vector2(center_x + radius * 0.65, bulb_y + radius * 0.1), radius * 0.58, dark.lightened(0.2))
	_draw_plant_pattern_overlay(canvas, dest, plant_pattern, detail, dark)


func _draw_plant_pattern_overlay(canvas: CanvasItem, dest: Rect2, pattern: String, detail: Color, dark: Color) -> void:
	var center := dest.get_center()
	var unit := maxf(1.0, floorf(dest.size.x / 16.0))
	match pattern:
		"cells":
			for cell in 3:
				canvas.draw_rect(Rect2(center + Vector2(-4.0 + float(cell) * 3.0, -2.0) * unit, Vector2.ONE * unit * 1.5), Color(detail, 0.8))
		"veins":
			canvas.draw_line(center + Vector2(-5, 4) * unit, center + Vector2(4, -4) * unit, Color(dark, 0.8), unit)
			canvas.draw_line(center, center + Vector2(5, 3) * unit, Color(detail, 0.75), unit)
		"crystals":
			canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(0, -4) * unit, center + Vector2(3, 0) * unit, center + Vector2(0, 3) * unit, center + Vector2(-3, 0) * unit]), Color(detail, 0.82))
		_:
			canvas.draw_circle(center + Vector2(-3, -1) * unit, unit * 1.2, Color(detail, 0.55))
			canvas.draw_circle(center + Vector2(3, 2) * unit, unit, Color(dark, 0.5))


func _draw_creature_eye(canvas: CanvasItem, position: Vector2, size: float, color: Color) -> void:
	canvas.draw_rect(Rect2(position - Vector2.ONE * size * 0.5, Vector2.ONE * size), color)


func legacy_creature_morphology(shape: String) -> Dictionary:
	var base := {
		"body_plan": "blob", "body_shape": "round", "head_shape": "round",
		"limbs": {"type": "none", "count": 0, "length": 0.5},
		"ears": "none", "tail": "none", "covering": "smooth", "features": [],
		"proportions": {"head": 0.9, "body": 1.0},
	}
	match shape:
		"fox": base.merge({"body_plan": "quadruped", "body_shape": "compact", "head_shape": "muzzle", "limbs": {"type": "legs", "count": 4, "length": 0.55}, "ears": "pointed", "tail": "bushy", "covering": "fur", "features": ["chest_patch"]}, true)
		"antlered": base.merge({"body_plan": "quadruped", "body_shape": "long", "head_shape": "muzzle", "limbs": {"type": "legs", "count": 4, "length": 0.7}, "ears": "round", "tail": "short", "covering": "fur", "features": ["antlers"]}, true)
		"penguin": base.merge({"body_plan": "biped", "body_shape": "compact", "head_shape": "beaked", "limbs": {"type": "flippers", "count": 2, "length": 0.55}, "tail": "short", "covering": "feathers", "features": ["chest_patch"]}, true)
		"crab": base.merge({"body_plan": "crawler", "body_shape": "wide", "head_shape": "flat", "limbs": {"type": "legs", "count": 6, "length": 0.5}, "covering": "shell", "features": ["claws", "eye_stalks"]}, true)
		"slug": base.merge({"body_plan": "serpentine", "body_shape": "long", "limbs": {"type": "none", "count": 0, "length": 0.4}, "tail": "short", "features": ["antennae"]}, true)
		"fish": base.merge({"body_plan": "fishlike", "body_shape": "long", "head_shape": "flat", "limbs": {"type": "fins", "count": 2, "length": 0.5}, "tail": "forked", "covering": "scales"}, true)
		"winged": base.merge({"body_plan": "biped", "body_shape": "compact", "limbs": {"type": "wings", "count": 2, "length": 0.8}, "tail": "short", "covering": "feathers"}, true)
		"crawler": base.merge({"body_plan": "crawler", "body_shape": "wide", "head_shape": "flat", "limbs": {"type": "legs", "count": 6, "length": 0.45}}, true)
		"long": base.merge({"body_plan": "serpentine", "body_shape": "long", "tail": "long"}, true)
	return base


func creature_morphology(definition: Dictionary, override: Dictionary = {}) -> Dictionary:
	if not override.is_empty():
		return override
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var morphology: Dictionary = visual.get("morphology", {}) if visual.get("morphology", {}) is Dictionary else {}
	return morphology if not morphology.is_empty() else legacy_creature_morphology(str(visual.get("body_shape", "round")))


func creature_hitboxes(dest: Rect2, definition: Dictionary, facing: int = 1, hybrid_morphology: Dictionary = {}) -> Array[Rect2]:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var morphology := creature_morphology(definition, hybrid_morphology)
	if not morphology.is_empty() and (visual.has("morphology") or not hybrid_morphology.is_empty()):
		var center := dest.get_center()
		var w := dest.size.x
		var h := dest.size.y
		var side := 1.0 if facing >= 0 else -1.0
		var body_plan := str(morphology.get("body_plan", "blob"))
		var torso_shape := str(morphology.get("body_shape", "round"))
		var proportions: Dictionary = morphology.get("proportions", {}) if morphology.get("proportions", {}) is Dictionary else {}
		var body_scale := clampf(float(proportions.get("body", 1.0)), 0.6, 1.4)
		var head_scale := clampf(float(proportions.get("head", 0.9)), 0.6, 1.4)
		var body_w := w * (0.62 if torso_shape in ["compact", "round"] else (0.82 if torso_shape == "long" else 0.9)) * body_scale
		var body_h := h * (0.46 if body_plan not in ["biped", "blob"] else 0.58) * body_scale
		if body_plan == "plantlike":
			body_h = h * 0.42 * body_scale
		if torso_shape == "wide":
			body_h *= 0.72
		var body_center := center + Vector2(0, h * (0.06 if body_plan != "biped" else 0.04))
		var head_center := body_center + (Vector2(side * body_w * 0.48, -body_h * 0.2) if body_plan in ["quadruped", "crawler", "serpentine", "fishlike"] else Vector2(0, -body_h * (0.72 if body_plan == "plantlike" else 0.48)))
		var head_size := Vector2(w * 0.28, h * 0.3) * head_scale
		return [
			Rect2(body_center - Vector2(body_w, body_h) * 0.5, Vector2(body_w, body_h)),
			Rect2(head_center - head_size * 0.5, head_size),
		]

	var center := dest.get_center()
	var w := dest.size.x
	var h := dest.size.y
	var side := 1.0 if facing >= 0 else -1.0
	match str(visual.get("body_shape", "round")):
		"fox":
			var head := center + Vector2(side * w * 0.27, -h * 0.13)
			return [Rect2(center + Vector2(-w * 0.31, -h * 0.08), Vector2(w * 0.52, h * 0.34)), Rect2(head - Vector2(w * 0.15, h * 0.2), Vector2(w * 0.3, h * 0.4))]
		"antlered":
			var head := center + Vector2(side * w * 0.3, -h * 0.12)
			return [Rect2(center + Vector2(-w * 0.32, -h * 0.03), Vector2(w * 0.56, h * 0.34)), Rect2(head - Vector2(w * 0.12, h * 0.17), Vector2(w * 0.24, h * 0.34))]
		"penguin":
			return [Rect2(center + Vector2(-w * 0.2, -h * 0.34), Vector2(w * 0.4, h * 0.72))]
		"crab":
			return [Rect2(center + Vector2(-w * 0.47, -h * 0.22), Vector2(w * 0.94, h * 0.46))]
		"slug":
			var head := center + Vector2(side * w * 0.25, -h * 0.04)
			return [
				Rect2(center + Vector2(-w * 0.35, h * 0.02), Vector2(w * 0.7, h * 0.24)),
				Rect2(head - Vector2(w * 0.14, h * 0.15), Vector2(w * 0.28, h * 0.3)),
				Rect2(center + Vector2(-side * w * 0.3 - w * 0.1, -h * 0.04), Vector2(w * 0.28, h * 0.2)),
			]
		"fish":
			return [Rect2(center + Vector2(-w * 0.52, -h * 0.25), Vector2(w * 0.8, h * 0.5))]

	var shape := str(visual.get("body_shape", "round"))
	var body_w := dest.size.x * (0.72 if shape != "long" else 0.9)
	var body_h := dest.size.y * (0.58 if shape != "crawler" else 0.38)
	return [Rect2(center.x - body_w * 0.5, center.y - body_h * 0.35, body_w, body_h)]


func _draw_creature_pattern(canvas: CanvasItem, center: Vector2, size: Vector2, pattern: String, accent: Color, detail: Color) -> void:
	match pattern:
		"patches":
			canvas.draw_rect(Rect2(center + Vector2(-size.x * 0.34, -size.y * 0.2), Vector2(size.x * 0.3, size.y * 0.38)), accent)
			canvas.draw_rect(Rect2(center + Vector2(size.x * 0.1, size.y * 0.02), Vector2(size.x * 0.22, size.y * 0.23)), detail)
		"stripes":
			for stripe in 3:
				var stripe_x := center.x - size.x * 0.32 + float(stripe) * size.x * 0.28
				canvas.draw_rect(Rect2(stripe_x, center.y - size.y * 0.38, maxf(1.0, size.x * 0.09), size.y * 0.76), accent)
		"spots":
			for spot in 4:
				var spot_x := center.x + (-0.28 + float(spot % 2) * 0.52) * size.x
				var spot_y := center.y + (-0.2 + float(spot / 2) * 0.38) * size.y
				canvas.draw_circle(Vector2(spot_x, spot_y), maxf(1.0, minf(size.x, size.y) * 0.1), accent if spot % 2 == 0 else detail)
		"mottled":
			for mark in 5:
				var mark_x := center.x + (-0.34 + float((mark * 3) % 5) * 0.17) * size.x
				var mark_y := center.y + (-0.27 + float((mark * 2) % 4) * 0.18) * size.y
				canvas.draw_rect(Rect2(Vector2(mark_x, mark_y), Vector2(maxf(1.0, size.x * 0.11), maxf(1.0, size.y * 0.12))), accent.darkened(0.08))
		"gradient":
			canvas.draw_rect(Rect2(center + Vector2(-size.x * 0.46, 0), Vector2(size.x * 0.92, size.y * 0.32)), Color(accent, 0.72))


func plantlike_root_segments(dest: Rect2, morphology: Dictionary) -> Array[PackedVector2Array]:
	var segments: Array[PackedVector2Array] = []
	if str(morphology.get("body_plan", "blob")) != "plantlike":
		return segments
	var proportions: Dictionary = morphology.get("proportions", {}) if morphology.get("proportions", {}) is Dictionary else {}
	var body_scale := clampf(float(proportions.get("body", 1.0)), 0.6, 1.4)
	var body_h := dest.size.y * 0.42 * body_scale
	if str(morphology.get("body_shape", "round")) == "wide":
		body_h *= 0.72
	var body_center := dest.get_center() + Vector2(0, dest.size.y * 0.06)
	var root_start_y := body_center.y + body_h * 0.28
	for side in [-1.0, 1.0]:
		segments.append(PackedVector2Array([
			Vector2(body_center.x + side * dest.size.x * 0.11, root_start_y),
			Vector2(body_center.x + side * dest.size.x * 0.16, dest.end.y),
		]))
	return segments


func _draw_composed_creature(canvas: CanvasItem, dest: Rect2, morphology: Dictionary, body: Color, accent: Color, detail: Color, eye_color: Color, eye_count: int, facing: int, color_pattern: String = "solid") -> void:
	var center := dest.get_center()
	var w := dest.size.x
	var h := dest.size.y
	var side := 1.0 if facing >= 0 else -1.0
	var body_plan := str(morphology.get("body_plan", "blob"))
	var torso_shape := str(morphology.get("body_shape", "round"))
	var head_shape := str(morphology.get("head_shape", "round"))
	var proportions: Dictionary = morphology.get("proportions", {}) if morphology.get("proportions", {}) is Dictionary else {}
	var body_scale := clampf(float(proportions.get("body", 1.0)), 0.6, 1.4)
	var head_scale := clampf(float(proportions.get("head", 0.9)), 0.6, 1.4)
	var body_w := w * (0.62 if torso_shape in ["compact", "round"] else (0.82 if torso_shape == "long" else 0.9)) * body_scale
	var body_h := h * (0.46 if body_plan not in ["biped", "blob"] else 0.58) * body_scale
	if body_plan == "plantlike": body_h = h * 0.42 * body_scale
	if torso_shape == "wide": body_h *= 0.72
	var body_center := center + Vector2(0, h * (0.06 if body_plan != "biped" else 0.04))
	var head_center := body_center + (Vector2(side * body_w * 0.48, -body_h * 0.2) if body_plan in ["quadruped", "crawler", "serpentine", "fishlike"] else Vector2(0, -body_h * (0.72 if body_plan == "plantlike" else 0.48)))
	var head_size := Vector2(w * 0.28, h * 0.3) * head_scale
	var tail := str(morphology.get("tail", "none"))
	var tail_root := body_center - Vector2(side * body_w * 0.46, 0)
	if tail in ["long", "bushy", "short"]:
		var tail_length := w * (0.46 if tail != "short" else 0.2)
		var tail_width := maxf(2.0, h * (0.17 if tail == "bushy" else 0.07))
		canvas.draw_line(tail_root, tail_root - Vector2(side * tail_length, h * (0.18 if tail == "bushy" else 0.02)), accent, tail_width)
	elif tail in ["forked", "fin"]:
		var tail_tip := tail_root - Vector2(side * w * 0.32, 0)
		canvas.draw_colored_polygon(PackedVector2Array([tail_root, tail_tip + Vector2(0, -h * 0.24), tail_tip, tail_tip + Vector2(0, h * 0.24)]), accent)
	var limbs: Dictionary = morphology.get("limbs", {}) if morphology.get("limbs", {}) is Dictionary else {}
	var limb_type := str(limbs.get("type", "none"))
	var limb_count := clampi(int(limbs.get("count", 0)), 0, 8)
	var limb_length := clampf(float(limbs.get("length", 0.5)), 0.2, 1.4)
	if limb_type == "wings":
		for wing_side in [-1.0, 1.0]:
			canvas.draw_colored_polygon(PackedVector2Array([body_center, body_center + Vector2(wing_side * w * 0.48 * limb_length, -h * 0.32), body_center + Vector2(wing_side * w * 0.34, h * 0.2)]), accent)
	elif limb_type in ["fins", "flippers"]:
		for fin_side in [-1.0, 1.0]:
			canvas.draw_colored_polygon(PackedVector2Array([body_center + Vector2(fin_side * body_w * 0.18, 0), body_center + Vector2(fin_side * w * 0.42 * limb_length, h * 0.18), body_center + Vector2(fin_side * body_w * 0.08, h * 0.22)]), accent)
	elif limb_type in ["legs", "tentacles"] and limb_count > 0:
		for limb_index in limb_count:
			var column := float(limb_index) / maxf(1.0, float(limb_count - 1)) - 0.5
			var root := body_center + Vector2(column * body_w * 0.8, body_h * 0.32)
			var end := root + Vector2(column * w * 0.06, h * (0.22 if limb_type == "legs" else 0.3) * limb_length)
			canvas.draw_line(root, end, detail if limb_index % 2 == 0 else accent, maxf(2.0, w * 0.055))
	# Generated rooted creatures may have short limbs and no optional vines. In
	# that case the occupied air cell is valid but every painted pixel can end
	# above its supporting block. Give every plantlike body a baseline root,
	# independent of its random morphology details.
	var root_segments := plantlike_root_segments(dest, morphology)
	for root_index in root_segments.size():
		var segment: PackedVector2Array = root_segments[root_index]
		canvas.draw_line(segment[0], segment[1], detail if root_index % 2 == 0 else accent, maxf(2.0, w * 0.055))
	canvas.draw_rect(Rect2(body_center - Vector2(body_w, body_h) * 0.5, Vector2(body_w, body_h)), body)
	_draw_creature_pattern(canvas, body_center, Vector2(body_w, body_h), color_pattern, accent, detail)
	if str(morphology.get("covering", "smooth")) in ["scales", "feathers", "fur"]:
		for mark in 3:
			canvas.draw_rect(Rect2(body_center + Vector2(-body_w * 0.25 + mark * body_w * 0.22, -body_h * 0.12), Vector2(w * 0.07, h * 0.07)), accent.darkened(0.08))
	if head_shape == "beaked":
		canvas.draw_rect(Rect2(head_center - head_size * 0.5, head_size), body)
		canvas.draw_colored_polygon(PackedVector2Array([head_center + Vector2(side * head_size.x * 0.45, -head_size.y * 0.08), head_center + Vector2(side * head_size.x * 0.85, head_size.y * 0.05), head_center + Vector2(side * head_size.x * 0.45, head_size.y * 0.18)]), detail)
	elif head_shape == "muzzle":
		canvas.draw_rect(Rect2(head_center - head_size * 0.5, head_size), body)
		canvas.draw_rect(Rect2(head_center + Vector2(side * head_size.x * 0.18, head_size.y * 0.05) - Vector2(head_size.x * 0.16, head_size.y * 0.1), Vector2(head_size.x * 0.32, head_size.y * 0.2)), accent)
	else:
		canvas.draw_rect(Rect2(head_center - head_size * 0.5, head_size), body if head_shape != "flat" else accent)
	var ears := str(morphology.get("ears", "none"))
	if ears != "none":
		for ear_side in [-1.0, 1.0]:
			var ear_x: float = head_center.x + float(ear_side) * head_size.x * 0.27
			var ear_height: float = head_size.y * (0.55 if ears == "long" else 0.32)
			if ears == "pointed":
				canvas.draw_colored_polygon(PackedVector2Array([Vector2(ear_x - w * 0.05, head_center.y - head_size.y * 0.42), Vector2(ear_x, head_center.y - head_size.y * 0.42 - ear_height), Vector2(ear_x + w * 0.05, head_center.y - head_size.y * 0.42)]), accent)
			else:
				canvas.draw_rect(Rect2(ear_x - w * 0.055, head_center.y - head_size.y * 0.45 - ear_height, w * 0.11, ear_height), accent)
	var features: Array = morphology.get("features", []) if morphology.get("features", []) is Array else []
	if "chest_patch" in features:
		canvas.draw_rect(Rect2(body_center + Vector2(-body_w * 0.13, -body_h * 0.08), Vector2(body_w * 0.26, body_h * 0.38)), accent)
	if "shell" in features:
		canvas.draw_rect(Rect2(body_center + Vector2(-body_w * 0.25, -body_h * 0.34), Vector2(body_w * 0.5, body_h * 0.38)), detail)
	if "horns" in features or "antlers" in features:
		for horn_side in [-1.0, 1.0]:
			var horn_root := head_center + Vector2(horn_side * head_size.x * 0.2, -head_size.y * 0.45)
			canvas.draw_line(horn_root, horn_root + Vector2(horn_side * w * 0.08, -h * (0.2 if "antlers" in features else 0.13)), detail, maxf(2.0, w * 0.045))
	if "antennae" in features or "eye_stalks" in features:
		for antenna_side in [-1.0, 1.0]:
			var antenna_root := head_center + Vector2(antenna_side * head_size.x * 0.18, -head_size.y * 0.35)
			canvas.draw_line(antenna_root, antenna_root + Vector2(antenna_side * w * 0.07, -h * 0.18), accent, maxf(1.5, w * 0.035))
	if "claws" in features:
		for claw_side in [-1.0, 1.0]:
			canvas.draw_rect(Rect2(body_center + Vector2(claw_side * body_w * 0.48 - w * 0.06, -body_h * 0.18), Vector2(w * 0.12, h * 0.14)), detail)
	if "arms" in features:
		for arm_side in [-1.0, 1.0]:
			var arm_root := body_center + Vector2(arm_side * body_w * 0.42, -body_h * 0.12)
			canvas.draw_line(arm_root, arm_root + Vector2(arm_side * w * 0.13, h * 0.27), accent, maxf(2.0, w * 0.055))
	if "tool_belt" in features:
		canvas.draw_line(body_center + Vector2(-body_w * 0.38, body_h * 0.12), body_center + Vector2(body_w * 0.38, body_h * 0.12), detail, maxf(2.0, h * 0.055))
	if "satchel" in features:
		canvas.draw_rect(Rect2(body_center + Vector2(side * body_w * 0.18 - w * 0.07, body_h * 0.04), Vector2(w * 0.14, h * 0.17)), detail)
	if "vines" in features:
		canvas.draw_line(body_center + Vector2(-body_w * 0.18, body_h * 0.25), center + Vector2(-w * 0.2, h * 0.46), accent, maxf(2.0, w * 0.05))
		canvas.draw_line(body_center + Vector2(body_w * 0.18, body_h * 0.25), center + Vector2(w * 0.2, h * 0.46), accent, maxf(2.0, w * 0.05))
	if "petals" in features:
		for petal_index in 6:
			var angle := TAU * float(petal_index) / 6.0
			canvas.draw_circle(head_center + Vector2(cos(angle), sin(angle)) * head_size.x * 0.58, head_size.x * 0.22, accent)
	if "thorns" in features:
		for thorn_side in [-1.0, 1.0]:
			canvas.draw_colored_polygon(PackedVector2Array([body_center + Vector2(thorn_side * body_w * 0.35, 0), body_center + Vector2(thorn_side * body_w * 0.62, -h * 0.08), body_center + Vector2(thorn_side * body_w * 0.42, h * 0.08)]), detail)
	var eye_size := maxf(2.0, minf(w, h) * 0.075)
	for eye_index in clampi(eye_count, 1, 4):
		var eye_row := eye_index / 2
		var eye_col := eye_index % 2
		var eye_pos := head_center + Vector2(side * head_size.x * (0.16 + eye_col * 0.14), -head_size.y * 0.12 + eye_row * head_size.y * 0.22)
		_draw_creature_eye(canvas, eye_pos, eye_size, eye_color)


func _draw_recognizable_creature(canvas: CanvasItem, dest: Rect2, shape: String, body: Color, accent: Color, detail: Color, eye_color: Color, facing: int) -> bool:
	var center := dest.get_center()
	var w := dest.size.x
	var h := dest.size.y
	var side := 1.0 if facing >= 0 else -1.0
	var eye_size := maxf(2.0, minf(w, h) * 0.09)
	match shape:
		"fox":
			canvas.draw_rect(Rect2(center + Vector2(-w * 0.31, -h * 0.08), Vector2(w * 0.52, h * 0.34)), body)
			var fox_head: Vector2 = center + Vector2(side * w * 0.27, -h * 0.13)
			canvas.draw_rect(Rect2(fox_head - Vector2(w * 0.15, h * 0.2), Vector2(w * 0.3, h * 0.4)), body)
			for ear_side in [-1.0, 1.0]:
				var ear_x: float = fox_head.x + float(ear_side) * w * 0.09
				canvas.draw_colored_polygon(PackedVector2Array([Vector2(ear_x - w * 0.055, fox_head.y - h * 0.17), Vector2(ear_x, fox_head.y - h * 0.36), Vector2(ear_x + w * 0.055, fox_head.y - h * 0.17)]), body)
			canvas.draw_rect(Rect2(fox_head + Vector2(side * w * 0.01 - w * 0.1, h * 0.02), Vector2(w * 0.2, h * 0.15)), accent)
			var tail_root: Vector2 = center + Vector2(-side * w * 0.28, h * 0.02)
			var tail_tip: Vector2 = center + Vector2(-side * w * 0.48, -h * 0.15)
			canvas.draw_line(tail_root, tail_tip, body, maxf(3.0, h * 0.22))
			canvas.draw_line(tail_tip, tail_tip + Vector2(side * w * 0.09, h * 0.06), accent, maxf(2.0, h * 0.16))
			for leg_x in [-0.2, 0.12]:
				canvas.draw_rect(Rect2(center + Vector2(w * leg_x, h * 0.2), Vector2(w * 0.09, h * 0.23)), detail)
			_draw_creature_eye(canvas, fox_head + Vector2(side * w * 0.055, -h * 0.06), eye_size, eye_color)
			return true
		"antlered":
			canvas.draw_rect(Rect2(center + Vector2(-w * 0.32, -h * 0.03), Vector2(w * 0.56, h * 0.34)), body)
			var antler_head: Vector2 = center + Vector2(side * w * 0.3, -h * 0.12)
			canvas.draw_rect(Rect2(antler_head - Vector2(w * 0.12, h * 0.17), Vector2(w * 0.24, h * 0.34)), body)
			for leg_x in [-0.22, 0.12]:
				canvas.draw_rect(Rect2(center + Vector2(w * leg_x, h * 0.25), Vector2(w * 0.075, h * 0.25)), detail)
			for antler_side in [-1.0, 1.0]:
				var root: Vector2 = antler_head + Vector2(float(antler_side) * w * 0.07, -h * 0.14)
				canvas.draw_line(root, root + Vector2(antler_side * w * 0.04, -h * 0.24), accent, maxf(2.0, w * 0.045))
				canvas.draw_line(root + Vector2(antler_side * w * 0.03, -h * 0.12), root + Vector2(antler_side * w * 0.12, -h * 0.18), accent, maxf(2.0, w * 0.04))
			_draw_creature_eye(canvas, antler_head + Vector2(side * w * 0.05, -h * 0.02), eye_size, eye_color)
			return true
		"penguin":
			canvas.draw_rect(Rect2(center + Vector2(-w * 0.2, -h * 0.34), Vector2(w * 0.4, h * 0.68)), body)
			canvas.draw_rect(Rect2(center + Vector2(-w * 0.12, -h * 0.12), Vector2(w * 0.24, h * 0.38)), accent)
			canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(side * w * 0.18, -h * 0.18), center + Vector2(side * w * 0.34, -h * 0.12), center + Vector2(side * w * 0.18, -h * 0.06)]), detail)
			for foot_side in [-1.0, 1.0]:
				canvas.draw_rect(Rect2(center + Vector2(foot_side * w * 0.11 - w * 0.06, h * 0.31), Vector2(w * 0.13, h * 0.07)), detail)
			_draw_creature_eye(canvas, center + Vector2(side * w * 0.08, -h * 0.23), eye_size, eye_color)
			return true
		"crab":
			canvas.draw_rect(Rect2(center + Vector2(-w * 0.28, -h * 0.1), Vector2(w * 0.56, h * 0.28)), body)
			for leg_side in [-1.0, 1.0]:
				for row in 3:
					var leg_y: float = center.y + h * (0.02 + float(row) * 0.08)
					canvas.draw_line(Vector2(center.x + leg_side * w * 0.23, leg_y), Vector2(center.x + leg_side * w * (0.35 + float(row) * 0.035), leg_y + h * 0.12), accent, maxf(2.0, h * 0.055))
				var claw_center: Vector2 = center + Vector2(float(leg_side) * w * 0.39, -h * 0.15)
				canvas.draw_line(center + Vector2(leg_side * w * 0.24, -h * 0.03), claw_center, body, maxf(2.0, h * 0.08))
				canvas.draw_rect(Rect2(claw_center - Vector2(w * 0.08, h * 0.07), Vector2(w * 0.16, h * 0.14)), body)
			for eye_side in [-1.0, 1.0]:
				var eye_position: Vector2 = center + Vector2(float(eye_side) * w * 0.13, -h * 0.18)
				canvas.draw_line(eye_position + Vector2(0, h * 0.12), eye_position, accent, maxf(2.0, w * 0.035))
				_draw_creature_eye(canvas, eye_position, eye_size, eye_color)
			return true
		"slug":
			canvas.draw_rect(Rect2(center + Vector2(-w * 0.35, h * 0.02), Vector2(w * 0.7, h * 0.24)), accent)
			var slug_head: Vector2 = center + Vector2(side * w * 0.25, -h * 0.04)
			canvas.draw_rect(Rect2(slug_head - Vector2(w * 0.14, h * 0.15), Vector2(w * 0.28, h * 0.3)), body)
			canvas.draw_rect(Rect2(center + Vector2(-side * w * 0.3 - w * 0.1, -h * 0.04), Vector2(w * 0.28, h * 0.2)), body)
			for feeler_y in [-0.08, 0.04]:
				var feeler_end: Vector2 = slug_head + Vector2(side * w * 0.2, h * float(feeler_y) - h * 0.12)
				canvas.draw_line(slug_head + Vector2(side * w * 0.08, h * feeler_y), feeler_end, detail, maxf(1.5, w * 0.03))
			_draw_creature_eye(canvas, slug_head + Vector2(side * w * 0.08, -h * 0.06), eye_size, eye_color)
			return true
		"fish":
			canvas.draw_rect(Rect2(center + Vector2(-w * 0.28, -h * 0.17), Vector2(w * 0.56, h * 0.34)), body)
			var tail_x: float = center.x - side * w * 0.28
			canvas.draw_colored_polygon(PackedVector2Array([Vector2(tail_x, center.y), Vector2(tail_x - side * w * 0.24, center.y - h * 0.25), Vector2(tail_x - side * w * 0.24, center.y + h * 0.25)]), accent)
			canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(-side * w * 0.02, 0), center + Vector2(-side * w * 0.17, h * 0.25), center + Vector2(side * w * 0.12, h * 0.13)]), detail)
			_draw_creature_eye(canvas, center + Vector2(side * w * 0.18, -h * 0.055), eye_size, eye_color)
			return true
	return false


func draw_creature(canvas: CanvasItem, dest: Rect2, definition: Dictionary, facing: int = 1, hybrid_palette: Array = [], hybrid_morphology: Dictionary = {}, hybrid_pattern: String = "") -> void:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var palette: Array = hybrid_palette if not hybrid_palette.is_empty() else (visual.get("palette", []) if visual.get("palette", []) is Array else [])
	var body := Color(str(palette[0])) if palette.size() > 0 and Color.html_is_valid(str(palette[0])) else Color("#77543a")
	var accent := Color(str(palette[1])) if palette.size() > 1 and Color.html_is_valid(str(palette[1])) else Color("#f2c14e")
	var detail := Color(str(palette[2])) if palette.size() > 2 and Color.html_is_valid(str(palette[2])) else body.darkened(0.3)
	var shape := str(visual.get("body_shape", "round"))
	var eye_color := Color(str(visual.get("eye_color", "#151515"))) if Color.html_is_valid(str(visual.get("eye_color", "#151515"))) else Color("#151515")
	var morphology := creature_morphology(definition, hybrid_morphology)
	var color_pattern := hybrid_pattern if not hybrid_pattern.is_empty() else str(visual.get("pattern", "mottled"))
	if not morphology.is_empty() and (visual.has("morphology") or not hybrid_morphology.is_empty()):
		_draw_composed_creature(canvas, dest, morphology, body, accent, detail, eye_color, int(visual.get("eye_count", 2)), facing, color_pattern)
		return
	if _draw_recognizable_creature(canvas, dest, shape, body, accent, detail, eye_color, facing):
		return
	var center := dest.get_center()
	var bw := dest.size.x * (0.72 if shape != "long" else 0.9)
	var bh := dest.size.y * (0.58 if shape != "crawler" else 0.38)
	canvas.draw_rect(Rect2(center.x - bw * 0.5, center.y - bh * 0.35, bw, bh), body)
	if shape == "winged":
		canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(-bw * 0.25, 0), center + Vector2(-bw * 0.65, -bh * 0.45), center + Vector2(-bw * 0.55, bh * 0.3)]), accent)
		canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(bw * 0.25, 0), center + Vector2(bw * 0.65, -bh * 0.45), center + Vector2(bw * 0.55, bh * 0.3)]), accent)
	elif shape == "crawler":
		for i in 3:
			var lx := center.x - bw * 0.3 + float(i) * bw * 0.3
			canvas.draw_line(Vector2(lx, center.y + bh * 0.25), Vector2(lx - bw * 0.12, center.y + bh * 0.6), accent, maxf(1.0, dest.size.x * 0.05))
	var eyes := clampi(int(visual.get("eye_count", 2)), 1, 4)
	var eye_side := 1.0 if facing >= 0 else -1.0
	for i in eyes:
		var row := i / 2
		var col := i % 2
		var eye := center + Vector2(eye_side * bw * (0.22 + float(col) * 0.12), -bh * 0.08 + float(row) * bh * 0.22)
		canvas.draw_rect(Rect2(eye - Vector2.ONE * maxf(1.0, dest.size.x * 0.035), Vector2.ONE * maxf(2.0, dest.size.x * 0.07)), eye_color)


func draw_item(canvas: CanvasItem, dest: Rect2, definition: Dictionary) -> void:
	var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
	var palette: Array = visual.get("palette", []) if visual.get("palette", []) is Array else []
	var handle := Color(str(palette[0])) if palette.size() > 0 and Color.html_is_valid(str(palette[0])) else Color("#5b4630")
	var head := Color(str(palette[1])) if palette.size() > 1 and Color.html_is_valid(str(palette[1])) else Color("#d7b45a")
	var detail := Color(str(palette[2])) if palette.size() > 2 and Color.html_is_valid(str(palette[2])) else head.lightened(0.28)
	var shape := str(visual.get("shape", "pickaxe"))
	var center := dest.get_center()
	var scale := minf(dest.size.x, dest.size.y) / 32.0
	if shape == "boots":
		for side in [-1.0, 1.0]:
			canvas.draw_rect(Rect2(center + Vector2(side * 2.0 - 6.0, -10.0) * scale, Vector2(7.0, 14.0) * scale), handle)
			canvas.draw_rect(Rect2(center + Vector2(side * 4.0 - 7.0, 2.0) * scale, Vector2(10.0, 6.0) * scale), head)
	elif shape == "charm":
		canvas.draw_line(center + Vector2(0, -12) * scale, center + Vector2(0, -4) * scale, handle, maxf(2.0, 2.5 * scale))
		canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(0, -5) * scale, center + Vector2(8, 3) * scale, center + Vector2(0, 12) * scale, center + Vector2(-8, 3) * scale]), head)
	elif shape == "ingot":
		# A compact cast-metal bar: bright top, broad face, and a dark lower edge.
		canvas.draw_colored_polygon(PackedVector2Array([
			center + Vector2(-11, -3) * scale,
			center + Vector2(-6, -8) * scale,
			center + Vector2(10, -8) * scale,
			center + Vector2(13, -3) * scale,
		]), detail)
		canvas.draw_colored_polygon(PackedVector2Array([
			center + Vector2(-11, -3) * scale,
			center + Vector2(13, -3) * scale,
			center + Vector2(10, 7) * scale,
			center + Vector2(-8, 7) * scale,
		]), head)
		canvas.draw_line(center + Vector2(-8, 7) * scale, center + Vector2(10, 7) * scale, handle, maxf(1.0, 2.0 * scale))
		canvas.draw_line(center + Vector2(-5, 0) * scale, center + Vector2(7, 0) * scale, detail.lightened(0.12), maxf(1.0, 1.3 * scale))
	elif shape == "berries":
		canvas.draw_line(center + Vector2(0, -11) * scale, center + Vector2(-2, -3) * scale, handle, maxf(1.0, 2.0 * scale))
		canvas.draw_line(center + Vector2(0, -9) * scale, center + Vector2(7, -5) * scale, handle, maxf(1.0, 2.0 * scale))
		for offset: Vector2 in [Vector2(-6, -1), Vector2(2, -2), Vector2(7, 4), Vector2(-2, 7)]:
			canvas.draw_circle(center + offset * scale, 5.0 * scale, head)
			canvas.draw_circle(center + (offset + Vector2(-1.2, -1.4)) * scale, 1.3 * scale, detail)
	elif shape == "meal":
		canvas.draw_colored_polygon(PackedVector2Array([
			center + Vector2(-11, -2) * scale,
			center + Vector2(11, -2) * scale,
			center + Vector2(7, 9) * scale,
			center + Vector2(-7, 9) * scale,
		]), handle)
		canvas.draw_rect(Rect2(center + Vector2(-12, -4) * scale, Vector2(24, 4) * scale), detail)
		canvas.draw_circle(center + Vector2(-4, -5) * scale, 4.0 * scale, head)
		canvas.draw_circle(center + Vector2(4, -6) * scale, 4.5 * scale, head.lightened(0.12))
	elif shape == "bow":
		canvas.draw_arc(center + Vector2(-3, 0) * scale, 13.0 * scale, -PI * 0.48, PI * 0.48, 20, handle, maxf(2.0, 3.0 * scale))
		canvas.draw_line(center + Vector2(-3, -13) * scale, center + Vector2(-3, 13) * scale, head, maxf(1.0, 1.5 * scale))
	elif shape == "arrow":
		canvas.draw_line(center + Vector2(-11, 8) * scale, center + Vector2(9, -8) * scale, handle, maxf(1.5, 2.0 * scale))
		canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(12, -11) * scale, center + Vector2(5, -8) * scale, center + Vector2(9, -3) * scale]), detail)
	elif shape == "stick":
		canvas.draw_line(center + Vector2(-8, 11) * scale, center + Vector2(8, -11) * scale, handle, maxf(2.0, 3.0 * scale))
	elif shape == "string":
		canvas.draw_arc(center, 10.0 * scale, -PI * 0.8, PI * 0.8, 20, head, maxf(1.0, 1.8 * scale))
		canvas.draw_arc(center + Vector2(2, 0) * scale, 6.0 * scale, PI * 0.2, PI * 1.8, 16, detail, maxf(1.0, 1.4 * scale))
	elif shape == "flint":
		canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(-9, 4) * scale, center + Vector2(-3, -10) * scale, center + Vector2(10, -5) * scale, center + Vector2(7, 8) * scale]), head)
	elif shape == "feather":
		canvas.draw_line(center + Vector2(-7, 11) * scale, center + Vector2(7, -11) * scale, handle, maxf(1.0, 1.6 * scale))
		canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(-5, 5) * scale, center + Vector2(7, -11) * scale, center + Vector2(4, 4) * scale]), head)
	else:
		canvas.draw_line(center + Vector2(-7, 10) * scale, center + Vector2(6, -8) * scale, handle, maxf(3.0, 4.0 * scale))
	match shape:
		"boots", "charm", "ingot", "berries", "meal", "bow", "arrow", "stick", "string", "flint", "feather": pass
		"hammer": canvas.draw_rect(Rect2(center + Vector2(-5, -12) * scale, Vector2(15, 7) * scale), head)
		"blade":
			canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(3, -12) * scale, center + Vector2(10, -16) * scale, center + Vector2(7, -5) * scale]), head)
		"spear": canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(6, -8) * scale, center + Vector2(11, -16) * scale, center + Vector2(2, -11) * scale]), head)
		"drill": canvas.draw_colored_polygon(PackedVector2Array([center + Vector2(1, -9) * scale, center + Vector2(13, -13) * scale, center + Vector2(8, -3) * scale]), head)
		"claw":
			for i in 3: canvas.draw_line(center + Vector2(1 + i * 3, -7) * scale, center + Vector2(5 + i * 3, -14) * scale, head, maxf(1.5, 2.0 * scale))
		_: canvas.draw_line(center + Vector2(-5, -11) * scale, center + Vector2(11, -7) * scale, head, maxf(3.0, 5.0 * scale))
	var pattern := str(visual.get("pattern", "plain"))
	match pattern:
		"banded":
			canvas.draw_line(center + Vector2(-5, 1) * scale, center + Vector2(5, -5) * scale, head.lightened(0.22), maxf(1.0, 2.0 * scale))
		"inlaid":
			canvas.draw_circle(center + Vector2(1, -2) * scale, maxf(1.0, 2.4 * scale), head.lightened(0.3))
		"speckled":
			for speck in 3:
				canvas.draw_rect(Rect2(center + Vector2(-4 + speck * 4, -5 + (speck % 2) * 5) * scale, Vector2.ONE * maxf(1.0, 1.5 * scale)), head.lightened(0.2))
		"glowing":
			var light := head.lightened(0.42)
			for offset: Vector2 in [Vector2(-7, -8), Vector2(8, -5), Vector2(4, 7)]:
				var spark := center + offset * scale
				var arm := maxf(1.0, 1.7 * scale)
				canvas.draw_line(spark - Vector2(arm, 0), spark + Vector2(arm, 0), Color(light, 0.9), maxf(1.0, 0.8 * scale))
				canvas.draw_line(spark - Vector2(0, arm), spark + Vector2(0, arm), Color(light, 0.72), maxf(1.0, 0.8 * scale))
	var rarity := str(definition.get("rarity", "common"))
	if rarity == "legendary":
		var gold := Color("#ffd65c")
		var badge_center := dest.position + dest.size * Vector2(0.78, 0.22)
		var badge_radius := maxf(2.5, 3.2 * scale)
		canvas.draw_colored_polygon(PackedVector2Array([
			badge_center + Vector2(0, -badge_radius),
			badge_center + Vector2(badge_radius * 0.72, 0),
			badge_center + Vector2(0, badge_radius),
			badge_center + Vector2(-badge_radius * 0.72, 0),
		]), Color(gold, 0.95))
		var ray := badge_radius * 1.55
		canvas.draw_line(badge_center - Vector2(ray, 0), badge_center + Vector2(ray, 0), Color(gold.lightened(0.2), 0.68), maxf(1.0, 0.7 * scale))
		canvas.draw_line(badge_center - Vector2(0, ray), badge_center + Vector2(0, ray), Color(gold.lightened(0.2), 0.68), maxf(1.0, 0.7 * scale))


func draw_block(
	canvas: CanvasItem,
	tx: int,
	ty: int,
	block: Dictionary,
	modulate: Color,
	anim_frame: int,
	fluid_level: int,
	fluid_falling: bool,
	open_above: bool,
	dest: Rect2,
	bevel_mask: int = BEVEL_ALL
) -> void:
	var x: float = dest.position.x
	var y: float = dest.position.y
	var w: float = dest.size.x
	var h: float = dest.size.y
	var sx: float = w / float(TILE)
	var sy: float = h / float(TILE)
	var name: String = block.get("name", "stone")
	if block.get("item", false):
		draw_item(canvas, dest, block.get("definition", {}))
		return
	if block.get("creature_item", false):
		draw_creature(canvas, dest, block.get("definition", {}), 1)
		return
	if block.get("plant", false):
		draw_plant_cell(canvas, dest, block, 3, 0)
		return

	if block.get("fluid", false):
		_draw_fluid(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate, anim_frame, fluid_level, fluid_falling, open_above)
		return

	if name == "grass":
		_draw_grass(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate)
	elif name == "leaves":
		_draw_leaves(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate)
	elif name == "dirt":
		_draw_dirt(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate)
	elif name == "stone" or name == "cobblestone":
		_draw_stone(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate, name == "cobblestone")
	elif name == "wood":
		_draw_wood(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate, bevel_mask)
		_edge_bevel(canvas, x, y, w, h, sx, sy, modulate, bevel_mask & (BEVEL_TOP | BEVEL_BOTTOM))
		return
	elif name == "obsidian":
		_draw_obsidian(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate)
	elif name in ["glass", "tideglass"]:
		_draw_glass(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate)
	elif name == "chest":
		_draw_chest(canvas, x, y, w, h, sx, sy, block, modulate)
	elif name == "aged_chest":
		_draw_aged_chest(canvas, x, y, w, h, sx, sy, block, modulate)
	elif name == "death_cache":
		_draw_death_cache(canvas, x, y, w, h, sx, sy, modulate, anim_frame)
	elif name == "workbench":
		_draw_workbench(canvas, x, y, sx, sy, block, modulate)
	elif name == "furnace":
		_draw_furnace(canvas, x, y, sx, sy, block, modulate)
	elif block.get("generated", false):
		_draw_generated(canvas, tx, ty, x, y, w, h, sx, sy, block, modulate)
	else:
		canvas.draw_rect(Rect2(x, y, w, h), preview_color(block) * modulate)

	_edge_bevel(canvas, x, y, w, h, sx, sy, modulate, bevel_mask)
