-- Current Mythic+ season. Update this file when a new season starts.
--
-- wclEncounterID: the dungeon's ID on Warcraft Logs (used in links and API requests).
-- activityIDs:    Group Finder activity IDs for listings of this dungeon.
-- challengeMapID: the ID WoW uses for keystones (C_MythicPlus).
-- mapID:          the dungeon's instance map ID. Inferred from the Warcraft Logs ID
--                 (WCL uses a prefix + instance map ID); only used as a fallback.
local _, ns = ...

ns.Season = {
	name = "Midnight Season 2",
	wclZoneID = 55,
	dungeons = {
		{ name = "Altar of Fangs",       wclEncounterID = 12993,  challengeMapID = 588, mapID = 2993, activityIDs = { 1930, 1931, 1932, 1933 } },
		{ name = "Den of Nalorakk",      wclEncounterID = 12825,  challengeMapID = 586, mapID = 2825, activityIDs = { 1721, 1722, 1723, 1952 } },
		{ name = "Kings' Rest",          wclEncounterID = 61762,  challengeMapID = 249, mapID = 1762, activityIDs = { 512, 513, 514, 515, 660, 661 } },
		{ name = "Murder Row",           wclEncounterID = 12813,  challengeMapID = 587, mapID = 2813, activityIDs = { 1749, 1750, 1751, 1950 } },
		{ name = "Ruby Life Pools",      wclEncounterID = 112521, challengeMapID = 399, mapID = 2521, activityIDs = { 1173, 1174, 1175, 1176 } },
		{ name = "Temple of Sethraliss", wclEncounterID = 61877,  challengeMapID = 250, mapID = 1877, activityIDs = { 503, 504, 505, 542, 645 } },
		{ name = "The Blinding Vale",    wclEncounterID = 12859,  challengeMapID = 584, mapID = 2859, activityIDs = { 1699, 1700, 1701, 1949 } },
		{ name = "Voidscar Arena",       wclEncounterID = 12923,  challengeMapID = 585, mapID = 2923, activityIDs = { 1754, 1755, 1756, 1951 } },
	},
}
