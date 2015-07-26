/*
	SourcePawn is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	SourceMod is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	Pawn and SMALL are Copyright (C) 1997-2008 ITB CompuPhase.
	Source is Copyright (C) Valve Corporation.
	All trademarks are property of their respective owners.

	This program is free software: you can redistribute it and/or modify it
	under the terms of the GNU General Public License as published by the
	Free Software Foundation, either version 3 of the License, or (at your
	option) any later version.

	This program is distributed in the hope that it will be useful, but
	WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/* 
	Bibliography:
	'l4d2_scoremod' by CanadaRox, ProdigySim
	'damage_bonus' by CanadaRox, Stabby
	'l4d2_scoringwip' by ProdigySim
	'srs.scoringsystem' by AtomicStryker
	'eq2_scoremod' by Visor
*/

#pragma semicolon 1
#define SM_DEBUG 1

#include <sourcemod>
#include <sdkhooks>
#include <left4downtown>
#include <l4d2_direct>
#include <l4d2lib>

new	TEMP_HEALTH_MULTIPLIER 	= 1; //having a multiplier of x1 simplifies the numbers of all the types of temp health
new STARTING_PILL_BONUS		= 50; //for survivors to lose; applies to starting four pills only
new	SCAVENGED_PILL_PENALTY	= 50; //fast movement is its own reward, granting bonus for scavenged pills makes for a convoluted system
new	INCAP_HEALTH			= 30; //this for survivors to lose, and also handily accounts for the 30 temp health gained when revived
new	MAX_INCAPS				= 2;
new	TOTAL_INCAP_HEALTH		= 60;//@ fix to use INCAP_HEALTH * MAX_INCAPS;
new	MAX_HEALTH				= 100;
enum Teams
{
   TEAM_ONE, 
   TEAM_TWO 
};

new bool:bInSecondHalf = true; //flipped at the start of every round i.e. at the start of the game it becomes false
new bool:bIsRoundOver;
new Float:fBonusScore[2]; //the final health bonus for the round after map multiplier has been applied
new Float:fMapBonus;
new Float:fMapDistance;
new iTeamSize;
new iPillsConsumed;

//Interaction with external input
new Handle:hCVarPermHealthMultiplier; //x1.5 by default
new Handle:hCvarSurvivalBonus; //vanilla: 25 per survivor
new Handle:hCvarTieBreaker; //used to remove tiebreaker points

/*
	*Bonus: 
		+ total perm * multipler
		+ total temp * 1 
		+ 50 * Held pills 
		- 50 * Consumed pills
		- 30 * team incaps avoided 

	Map multiplier:
	total health bonus for map (2* map distance)
		divided by
	total bonus by full hp ( 100*perm multiplier + 60 (2 incaps) + 50 (pills) ) *4 survivors)
*/

public Plugin:myinfo = {
	name = "PIT Scoremod",
	author = "Newteee, Breezy",
	description = "A scoremod based on permanent, incap and temporary health bonus",
	version = "1.0",
	url = "https://github.com/breezyplease/pit-scoremod"
};

public OnPluginStart() {
	#if SM_DEBUG
		PrintToChatAll("Scoremod started.");
	#endif
	//Changing console variables
	hCvarSurvivalBonus = FindConVar("vs_survival_bonus");
	hCvarTieBreaker = FindConVar("vs_tiebreak_bonus");
	
	//.cfg variable
	hCVarPermHealthMultiplier = CreateConVar("perm_health_multiplier", "1.5", "Multiplier for permanent health");
	
	//Hooking game events to plugin functions
	HookEvent("round_start", EventHook:OnRoundStart, EventHookMode_PostNoCopy);
	HookEvent("pills_used", EventHook:OnPillsUsed, EventHookMode_PostNoCopy);
	
	//In-game "sm_/!" prefixed commands to call CmdBonus() function
	RegConsoleCmd("sm_health", CmdBonus);
	RegConsoleCmd("sm_damage", CmdBonus);
	RegConsoleCmd("sm_bonus", CmdBonus);
	//Map multiplier info, etc.
	RegConsoleCmd("sm_mapinfo", CmdMapInfo);
}

public OnConfigsExecuted() {
	SetConVarInt(hCvarTieBreaker, 0);
	iTeamSize = GetConVarInt(FindConVar("survivor_limit"));
	new iDistance = L4D2_GetMapValueInt( "max_distance", L4D_GetVersusMaxCompletionScore() );
	fMapDistance = float(iDistance);
	#if SM_DEBUG
		PrintToChatAll("Map distance: %d", fMapDistance);
	#endif
}

public OnRoundStart() {
	iPillsConsumed = 0;
	fMapBonus = CalculateBonusScore();
	bIsRoundOver = false;
	bInSecondHalf = !bInSecondHalf;
}

public OnPillsUsed() {
	iPillsConsumed++;
}

public Action:L4D2_OnEndVersusModeRound() { //bool:countSurvivors could possibly be used as a parameter here
	new team = 0;
	if (!bInSecondHalf) {
		team = TEAM_ONE;
	} else {
		team = TEAM_TWO;
	}
	fBonusScore[team] = CalculateBonusScore();
	//Check if team has wiped
	new iSurvivalMultiplier = CountUprightSurvivors();
	if (iSurvivalMultiplier == 0) { 
		PrintToChatAll("Survivors wiped out");
		return Plugin_Continue;
	} else if (fBonusScore[team] <= 0) {
		PrintToChatAll("Bonus depleted");
	}
	//Set score (L4D2 awards bonus on a per survivor basis -> divide calculated bonus by number of standing survivors)
	SetConvarInt(hCvarSurvivalBonus, RoundToFloor(fBonusScore[team]/iSurvivalMultiplier) );
	
	// Scores print
	CreateTimer(3.0, PrintRoundEndStats, _, TIMER_FLAG_NO_MAPCHANGE);
	bIsRoundOver = true;
	return Plugin_Continue;
}

//@TODO: fix the tag mismatch errors
public Action:PrintRoundEndStats(Handle:timer) {
	if (bInSecondHalf == false) {
		PrintToChatAll( "\x01[\x04SM\x01 :: Round \x031\x01] Bonus: \x05%d\x01/\x05%d\x01", RoundToFloor(fBonusScore[TEAM_ONE]), RoundToFloor(fMapBonus) );
		// [SM :: Round 1] Bonus: 487/1200 
	} else {
		PrintToChatAll( "\x01[\x04SM\x01 :: Round \x032\x01] Bonus: \x05%d\x01/\x05%d\x01", RoundToFloor(fBonusScore[TEAM_TWO]), RoundToFloor(fMapBonus) );
		// [SM :: Round 2] Bonus: 487/1200 
	}
}

public OnPluginEnd() {
	ResetConVar(hCvarSurvivalBonus);
	ResetConVar(hCvarTieBreaker);
}

public CvarChanged(Handle:convar, const String:oldValue[], const String:newValue[]) {
	OnConfigsExecuted(); //re-adjust if survivor_limit, perm health multiplier etc. are changed mid game
}

public Action:CmdBonus(client, args) {
	#if SM_DEBUG
		PrintToChatAll("CmdBonus() called");
	#endif
	if (bIsRoundOver || !client) {
		#if SM_DEBUG
			PrintToChatAll("bIsRoundOver = true || !client; ");
		#endif
		return Plugin_Handled;
	} else {
		new Float:fBonus = CalculateBonusScore();		
		if (!bInSecondHalf) {
			PrintToChat( client, "\x01[\x04SM\x01 :: R\x03#1\x01] Bonus: \x05%d\x01", RoundToFloor(fBonus));
			// [SM :: R#1] Bonus: 556
		} else { //Print for R#2
			PrintToChat( client, "\x01[\x04SM\x01 :: R\x03#2\x01] Bonus: \x05%d\x01", RoundToFloor(fBonus));
			// [SM :: R#2] Bonus: 556
		}	
	}	
}

public Action:CmdMapInfo(client, args) {
	PrintToChat(client, "\x01[\x04SM\x01 :: \x03	%iv%i\x01] Map Info", iTeamSize, iTeamSize); // [SM :: 4v4] Map Info
	PrintToChat(client, "\x01Map Distance: \x05%d\x01", fMapDistance);
	PrintToChat(client, "\x01Map Multiplier: \x05%d\x01", GetMapMultiplier()); // Map multiplier
	PrintToChat(client, "\x01Contribution to the temp bonus pools from each survivor is as follows:");
	PrintToChat(client, "\x01Starting pill bonus: 50");
	PrintToChat(client, "\x01Static incap bonus: 30 per incap avoided");
	PrintToChat(client, "\x01A 'scavenged pill penalty' of 50 is applied per pill consumed");

	return Plugin_Handled;
}

CountUprightSurvivors() {
	new iUprightCount = 0;
	new iSurvivorCount = 0;
	for (new i = 1; i <= MaxClients && iSurvivorCount < iTeamSize; i++)
	{
		if (IsSurvivor(i))
		{
			iSurvivorCount++;
			if (IsPlayerAlive(i) && !IsPlayerIncap(i) && !IsPlayerLedged(i))
			{
				iUprightCount++;
			}
		}
	}
	return iUprightCount;
}

bool:IsSurvivor(client) {
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2;
}

bool:IsPlayerIncap(client) {
	return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated");
}

bool:IsPlayerLedged(client)
{
	return bool:(GetEntProp(client, Prop_Send, "m_isHangingFromLedge") | GetEntProp(client, Prop_Send, "m_isFallingFromLedge"));
}

Float:CalculateBonusScore() {// Apply map multiplier to the sum of the permanent and temporary health bonuses
	new Float:fPermBonus = GetPermBonus();
	new Float:fTempBonus = GetTempBonus();
	new Float:fMapMultiplier = GetMapMultiplier();
	new Float:fHealth = fPermBonus + fTempBonus;
	new Float:fHealthBonus = fHealth * fMapMultiplier;
	return fHealthBonus;
}

// Permanent health held * multiplier (1.5 by default)
Float:GetPermBonus() { 
	new iPermHealth = 0;
	for (new index = 1; index < MaxClients; index++)
	{
		//Add permanent health held by each non-incapped survivor
		if (IsSurvivor(index) /*&& !IsPlayerIncap(index)*/) {  //@todo fix IsPlayerIncap
			if (GetEntProp(index, Prop_Send, "m_currentReviveCount") > 0 ) { //
				if (GetEntProp(index, Prop_Send, "m_iHealth") > 0) {
					iPermHealth += GetEntProp(index, Prop_Send, "m_iHealth");
				} 
			}
		}
	}		
	new Float:fPermBonus = iPermHealth * float(hCVarPermHealthMultiplier);
	#if SM_DEBUG
		PrintToChatAll("PermBonus: %f", fPermBonus);
	#endif
	return (fPermBonus > 0 ? fPermBonus: 0.0);
}

/*
Start with temp health held by survivors
Temp bonus is the same as temp health because of the x1 TEMP_HEALTH_MULTIPLIER
- subtract an 'incap penalty' to neutralise temp bonus gained when picked up  
- subtract a 'scavenged pills penalty' to neutralise temp bonus gained from non-starting pills
*/
Float:GetTempBonus() { 
	new iTempHealth = 0;
	new iIncapsSuffered = 0; 
	new iScavengedPillsEaten = ( (iPillsConsumed - iTeamSize) > 0 ? (iPillsConsumed - iTeamSize):0 );
	for (new index = 1; index < MaxClients; index++) {
		iIncapsSuffered += GetEntProp(index, Prop_Send, "m_currentReviveCount"); 
		if (IsSurvivor(index) /*@todo, fix && !(isPlayerIncap(index)*/) { //Non incapped player					
			//Add temp health held by each survivor
			iTempHealth += RoundToCeil(GetEntPropFloat(index, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(index, Prop_Send, "m_healthBufferTime")) * GetConVarFloat(FindConVar("pain_pills_decay_rate")))) - 1;
		}
	}	
	iTempHealth+= (iTeamSize * STARTING_PILL_BONUS);
	iTempHealth -= (iScavengedPillsEaten * SCAVENGED_PILL_PENALTY);
	iTempHealth -= (iIncapsSuffered * INCAP_HEALTH);
	new Float:fTempBonus = float(iTempHealth * TEMP_HEALTH_MULTIPLIER); // x1
	#if SM_DEBUG
		PrintToChatAll("TempBonus: %f", fTempBonus);
	#endif
	return (fTempBonus > 0 ? fTempBonus : 0);
}

Float:GetMapMultiplier() { // (2 * Map Distance)/Max health bonus (1040 by default w/ 1.5 perm health multiplier)
	new Float:fMaxPermBonus = MAX_HEALTH * float(hCVarPermHealthMultiplier);
	new Float:fMapMultiplier = ( 2 * fMapDistance )/( iTeamSize*(fMaxPermBonus + STARTING_PILL_BONUS + TOTAL_INCAP_HEALTH));
	#if SM_DEBUG
		PrintToChatAll("Map Multiplier: %f", fMapMultiplier);
	#endif
	return fMapMultiplier;
}
	