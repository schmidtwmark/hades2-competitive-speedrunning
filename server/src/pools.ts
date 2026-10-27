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

// KeepsakeData.lua ItemOrder. Display names here are placeholders derived from
// the ids; the mod shows the game's localized name when it can resolve one.
const KEEPSAKE_IDS = [
  "ManaOverTimeRefundKeepsake",
  "BossPreDamageKeepsake",
  "ReincarnationKeepsake",
  "DoorHealReserveKeepsake",
  "DeathVengeanceKeepsake",
  "BonusMoneyKeepsake",
  "BlockDeathKeepsake",
  "EscalatingKeepsake",
  "TimedBuffKeepsake",
  "LowHealthCritKeepsake",
  "SpellTalentKeepsake",
  "ForceZeusBoonKeepsake",
  "ForceHeraBoonKeepsake",
  "ForcePoseidonBoonKeepsake",
  "ForceDemeterBoonKeepsake",
  "ForceApolloBoonKeepsake",
  "ForceAphroditeBoonKeepsake",
  "ForceHephaestusBoonKeepsake",
  "ForceHestiaBoonKeepsake",
  "ForceAresBoonKeepsake",
  "AthenaEncounterKeepsake",
  "SkipEncounterKeepsake",
  "ArmorGainKeepsake",
  "FountainRarityKeepsake",
  "UnpickedBoonKeepsake",
  "DecayingBoostKeepsake",
  "DamagedDamageBoostKeepsake",
  "BossMetaUpgradeKeepsake",
  "TempHammerKeepsake",
  "HadesAndPersephoneKeepsake",
  "RarifyKeepsake",
  "GoldifyKeepsake",
  "RandomBlessingKeepsake",
];

function humanize(id: string): string {
  return id.replace(/Keepsake$/, "").replace(/([a-z])([A-Z])/g, "$1 $2");
}

export const KEEPSAKES: VoteOption[] = KEEPSAKE_IDS.map((id) => ({ id, name: humanize(id) }));

export function poolFor(phase: "weapon" | "keepsake"): VoteOption[] {
  return phase === "weapon" ? WEAPONS : KEEPSAKES;
}
