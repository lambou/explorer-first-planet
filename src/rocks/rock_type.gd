class_name RockType
extends RefCounted
## One kind of rock: pure data. The catalog (RockCatalog) makes them; the geology (RockField) decides where
## they lie; nothing here touches the world.

const FAMILY_STONE := "stone"            # base rocks that make up whole regions
const FAMILY_ORE := "ore"                # metals, fuels, salts: veins inside host rocks
const FAMILY_GEM := "gem"
const FAMILY_RADIOACTIVE := "radioactive"
const FAMILY_EXOTIC := "exotic"          # unknown types made from the seed

var id := 0
var key := ""                      # stable name used in rules ("granite")
var name := ""                     # shown to the player ("Granite"); exotics get invented names
var family := FAMILY_STONE
var color := Color.GRAY
var hardness := 1.0                # hits to break a 1 m rock (bigger rocks take more)
var density := 2.7                 # tonnes per cubic metre (a 1 m rock weighs this much)
var value := 1.0                   # worth of one unit of yield
var rarity := 1.0                  # 0..1: how often it shows where its rules allow it
var hosts := PackedStringArray()   # base rocks it can form in (empty = any); ores only
var min_depth := 0.0               # metres below the local natural surface (caves, deep rock) it needs
var alt_min := -10000.0            # metres above sea level (negative = sea bed)
var alt_max := 10000.0
var underwater_ok := true
var traits := {}                   # "radioactive", "magnetic", "brittle", "glow", ... -> strength 0..1
var vein_freq := 1.0 / 70.0        # size of the veins: 1 / (metres)
var center := Vector2.ZERO         # place in province space (base rocks)

func is_base() -> bool:
	return family == FAMILY_STONE

## Colour of the n-th piece with a little variation so two rocks of the same kind never look cloned.
func varied_color(v: float) -> Color:
	var k := 1.0 + (v - 0.5) * 0.22
	return Color(clampf(color.r * k, 0.0, 1.0), clampf(color.g * k, 0.0, 1.0), clampf(color.b * k, 0.0, 1.0))
