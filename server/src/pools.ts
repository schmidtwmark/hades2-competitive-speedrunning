import type { VoteOption } from "./protocol.js";

// Internal names are what the mod passes to the game. Keep these in sync with
// the game's WeaponData / TraitData (see NOTES.md for where each name was read).

// Where the run goes. The mod maps each id to the game's start in the Crossroads.
export const ALL_ROUTES: VoteOption[] = [
  { id: "underworld", name: "Underworld" },
  { id: "surface", name: "Surface" },
  { id: "dream", name: "Dream Dive" },
];

/** The routes on offer: all of ALL_ROUTES, or the ids in `list` ("underworld,surface"). */
export function routes(list?: string): VoteOption[] {
  if (!list) return ALL_ROUTES;
  const ids = list.split(",").map((x) => x.trim());
  return ALL_ROUTES.filter((r) => ids.includes(r.id));
}

// Regions by the code racers report as progress.biome (the game's RoomSetName;
// the mod's hud.lua has the same table).
export const REGIONS: Record<string, string> = {
  F: "Erebus",
  G: "Oceanus",
  H: "Fields of Mourning",
  I: "Tartarus",
  N: "Ephyra",
  O: "Thessaly",
  P: "Olympus",
  Q: "Summit",
  Chaos: "Chaos",
};

export const WEAPONS: VoteOption[] = [
  { id: "WeaponStaffSwing", name: "Witch's Staff" },
  { id: "WeaponDagger", name: "Sister Blades" },
  { id: "WeaponTorch", name: "Umbral Flames" },
  { id: "WeaponAxe", name: "Moonstone Axe" },
  { id: "WeaponLob", name: "Argent Skull" },
  { id: "WeaponSuit", name: "Black Coat" },
];

// KeepsakeData.lua ItemOrder, with the English names from the game's TraitText
// (the mod shows the game's localized name when it can resolve one).
export const KEEPSAKES: VoteOption[] = [
  { id: "ManaOverTimeRefundKeepsake", name: "Silver Wheel" },
  { id: "BossPreDamageKeepsake", name: "Knuckle Bones" },
  { id: "ReincarnationKeepsake", name: "Luckier Tooth" },
  { id: "DoorHealReserveKeepsake", name: "Ghost Onion" },
  { id: "DeathVengeanceKeepsake", name: "Evil Eye" },
  { id: "BonusMoneyKeepsake", name: "Gold Purse" },
  { id: "BlockDeathKeepsake", name: "Engraved Pin" },
  { id: "EscalatingKeepsake", name: "Discordant Bell" },
  { id: "TimedBuffKeepsake", name: "Metallic Droplet" },
  { id: "LowHealthCritKeepsake", name: "White Antler" },
  { id: "SpellTalentKeepsake", name: "Moon Beam" },
  { id: "ForceZeusBoonKeepsake", name: "Cloud Bangle" },
  { id: "ForceHeraBoonKeepsake", name: "Iridescent Fan" },
  { id: "ForcePoseidonBoonKeepsake", name: "Vivid Sea" },
  { id: "ForceDemeterBoonKeepsake", name: "Barley Sheaf" },
  { id: "ForceApolloBoonKeepsake", name: "Harmonic Photon" },
  { id: "ForceAphroditeBoonKeepsake", name: "Beautiful Mirror" },
  { id: "ForceHephaestusBoonKeepsake", name: "Adamant Shard" },
  { id: "ForceHestiaBoonKeepsake", name: "Everlasting Ember" },
  { id: "ForceAresBoonKeepsake", name: "Sword Hilt" },
  { id: "AthenaEncounterKeepsake", name: "Gorgon Amulet" },
  { id: "SkipEncounterKeepsake", name: "Fig Leaf" },
  { id: "ArmorGainKeepsake", name: "Silken Sash" },
  { id: "FountainRarityKeepsake", name: "Aromatic Phial" },
  { id: "UnpickedBoonKeepsake", name: "Concave Stone" },
  { id: "DecayingBoostKeepsake", name: "Lion Fang" },
  { id: "DamagedDamageBoostKeepsake", name: "Blackened Fleece" },
  { id: "BossMetaUpgradeKeepsake", name: "Crystal Figurine" },
  { id: "TempHammerKeepsake", name: "Experimental Hammer" },
  { id: "HadesAndPersephoneKeepsake", name: "Jeweled Pom" },
  { id: "RarifyKeepsake", name: "Calling Card" },
  { id: "GoldifyKeepsake", name: "Time Piece" },
  { id: "RandomBlessingKeepsake", name: "Transcendent Embryo" },
];

export function poolFor(phase: "weapon" | "keepsake"): VoteOption[] {
  return phase === "weapon" ? WEAPONS : KEEPSAKES;
}
