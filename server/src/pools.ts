import type { VoteOption } from "./protocol.js";

// Internal names are what the mod passes to the game. Keep these in sync with
// the game's WeaponData / TraitData (see NOTES.md for where each name was read).

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
