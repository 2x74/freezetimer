#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define CONFIG_FILE    "configs/freezetimer.cfg"
#define BLACKLIST_FILE "configs/freezetimer_blacklist.txt"

ConVar g_cvFrozenLabel;
ConVar g_cvTimeLimit;

float g_flVotePercent = 60.0;
int   g_iVoteDuration  = 20;
int   g_iCooldown      = 30;

bool   g_bFrozen;
int    g_iFrozenSecondsLeft;
Handle g_hHoldTimer;

bool   g_bVoteInProgress;
bool   g_bVoteIsFreeze;
int    g_iVoteYes;
int    g_iVoteNo;
bool   g_bClientVoted[MAXPLAYERS + 1];
int    g_iLastVoteAttempt[MAXPLAYERS + 1];
Handle g_hVoteEndTimer;

StringMap g_smBlacklist;

Handle g_hFwdStateChanged;

public Plugin myinfo =
{
	name        = "FreezeTimer",
	author      = "2x74 (luna)",
	description = "Freeze/unfreeze the map time limit.",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/2x74"
};

public void OnPluginStart()
{
	g_cvTimeLimit = FindConVar("mp_timelimit");

	g_cvFrozenLabel = CreateConVar("sv_frozenlabel", "0",
		"Append a [FROZEN] hint while the timer is frozen. Change via sm_frozenlabel (admin only).",
		FCVAR_NOTIFY);

	RegConsoleCmd("sm_freezetimer", Cmd_FreezeTimer,
		"Freeze the map time limit. Admins: instant. Others: starts a vote.");
	RegConsoleCmd("sm_unfreezetimer", Cmd_UnfreezeTimer,
		"Unfreeze the map time limit. Admins: instant. Others: starts a vote.");
	RegConsoleCmd("sm_ft", Cmd_FreezeTimer, "Alias for sm_freezetimer.");
	RegConsoleCmd("sm_uft", Cmd_UnfreezeTimer, "Alias for sm_unfreezetimer.");

	RegAdminCmd("sm_antifreeze", Cmd_AntiFreeze, ADMFLAG_GENERIC,
		"sm_antifreeze <#userid|name> - block a player from starting freeze/unfreeze votes.");
	RegAdminCmd("sm_allowfreeze", Cmd_AllowFreeze, ADMFLAG_GENERIC,
		"sm_allowfreeze <#userid|name> - remove a player's freeze-vote block.");
	RegAdminCmd("sm_frozenlabel", Cmd_FrozenLabel, ADMFLAG_GENERIC,
		"sm_frozenlabel <0|1> - toggle the [FROZEN] hint.");
	RegAdminCmd("sm_freezetimer_reload", Cmd_ReloadConfig, ADMFLAG_GENERIC,
		"Reload freezetimer.cfg without restarting the plugin.");

	g_smBlacklist = new StringMap();
	LoadConfig();
	LoadBlacklist();

	g_hFwdStateChanged = CreateGlobalForward("FreezeTimer_OnStateChanged", ET_Ignore, Param_Cell);
}

// cmds

public Action Cmd_FreezeTimer(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[FreezeTimer] Use rcon/sm_frozenlabel style commands from console; freezing requires a client.");
		return Plugin_Handled;
	}

	if (CheckCommandAccess(client, "sm_freezetimer", ADMFLAG_GENERIC, true))
	{
		DoFreeze(client, true);
	}
	else
	{
		TryStartVote(client, true);
	}
	return Plugin_Handled;
}

public Action Cmd_UnfreezeTimer(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[FreezeTimer] This needs to be run by a client.");
		return Plugin_Handled;
	}

	if (CheckCommandAccess(client, "sm_unfreezetimer", ADMFLAG_GENERIC, true))
	{
		DoUnfreeze(client, true);
	}
	else
	{
		TryStartVote(client, false);
	}
	return Plugin_Handled;
}

public Action Cmd_AntiFreeze(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: sm_antifreeze <#userid|name>");
		return Plugin_Handled;
	}

	char arg[65];
	GetCmdArg(1, arg, sizeof(arg));

	int target = FindTarget(client, arg, true, false);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	char steamId[32];
	if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId)))
	{
		ReplyToCommand(client, "[FreezeTimer] Couldn't get that player's SteamID.");
		return Plugin_Handled;
	}

	g_smBlacklist.SetValue(steamId, true);
	SaveBlacklist();

	char name[MAX_NAME_LENGTH];
	GetClientName(target, name, sizeof(name));
	PrintToChatAll("[FreezeTimer] %N blocked %s from starting freeze votes.", client, name);
	return Plugin_Handled;
}

public Action Cmd_AllowFreeze(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: sm_allowfreeze <#userid|name>");
		return Plugin_Handled;
	}

	char arg[65];
	GetCmdArg(1, arg, sizeof(arg));

	int target = FindTarget(client, arg, true, false);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	char steamId[32];
	if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId)))
	{
		ReplyToCommand(client, "[FreezeTimer] Couldn't get that player's SteamID.");
		return Plugin_Handled;
	}

	g_smBlacklist.Remove(steamId);
	SaveBlacklist();

	char name[MAX_NAME_LENGTH];
	GetClientName(target, name, sizeof(name));
	PrintToChatAll("[FreezeTimer] %N unblocked %s from starting freeze votes.", client, name);
	return Plugin_Handled;
}

public Action Cmd_FrozenLabel(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[FreezeTimer] sv_frozenlabel is currently %d. Usage: sm_frozenlabel <0|1>", g_cvFrozenLabel.IntValue);
		return Plugin_Handled;
	}

	char arg[4];
	GetCmdArg(1, arg, sizeof(arg));
	int val = StringToInt(arg) != 0 ? 1 : 0;
	g_cvFrozenLabel.IntValue = val;

	PrintToChatAll("[FreezeTimer] %N %s the [FROZEN] hint.", client, val ? "enabled" : "disabled");
	return Plugin_Handled;
}

public Action Cmd_ReloadConfig(int client, int args)
{
	LoadConfig();
	ReplyToCommand(client, "[FreezeTimer] Config reloaded (vote_percent %.1f, vote_duration %d, cooldown %d).",
		g_flVotePercent, g_iVoteDuration, g_iCooldown);
	return Plugin_Handled;
}

// come out with your hands up

void DoFreeze(int client, bool bBroadcast)
{
	if (g_bFrozen)
	{
		ReplyToClientOrChat(client, "[FreezeTimer] The timer is already frozen.");
		return;
	}

	int timeLeft;
	if (!GetMapTimeLeft(timeLeft) || timeLeft <= 0)
	{
		ReplyToClientOrChat(client, "[FreezeTimer] There's no active time limit to freeze.");
		return;
	}

	g_iFrozenSecondsLeft = timeLeft;
	g_bFrozen = true;
	g_hHoldTimer = CreateTimer(1.0, Timer_HoldTime, _, TIMER_REPEAT);

	Call_StartForward(g_hFwdStateChanged);
	Call_PushCell(true);
	Call_Finish();

	if (bBroadcast)
	{
		PrintToChatAll("[FreezeTimer] %N froze the map timer.", client);
	}
}

void DoUnfreeze(int client, bool bBroadcast)
{
	if (!g_bFrozen)
	{
		ReplyToClientOrChat(client, "[FreezeTimer] The timer isn't frozen.");
		return;
	}

	g_bFrozen = false;
	if (g_hHoldTimer != null)
	{
		KillTimer(g_hHoldTimer);
		g_hHoldTimer = null;
	}

	Call_StartForward(g_hFwdStateChanged);
	Call_PushCell(false);
	Call_Finish();

	if (bBroadcast)
	{
		PrintToChatAll("[FreezeTimer] %N unfroze the map timer.", client);
	}
}

public Action Timer_HoldTime(Handle timer)
{
	if (!g_bFrozen)
	{
		g_hHoldTimer = null;
		return Plugin_Stop;
	}

	int cur;
	if (GetMapTimeLeft(cur) && cur < g_iFrozenSecondsLeft - 2)
	{
		int minutesToAdd = RoundToCeil(float(g_iFrozenSecondsLeft - cur) / 60.0);

		int flags = g_cvTimeLimit.Flags;
		g_cvTimeLimit.Flags &= ~FCVAR_NOTIFY;

		ExtendMapTimeLimit(minutesToAdd);

		g_cvTimeLimit.Flags = flags;
	}

	return Plugin_Continue;
}

// yes i made a democratic plugin i'm so proud of myself

void TryStartVote(int client, bool bFreezeAction)
{
	if (g_bVoteInProgress)
	{
		ReplyToCommand(client, "[FreezeTimer] A vote is already in progress.");
		return;
	}
	if (bFreezeAction && g_bFrozen)
	{
		ReplyToCommand(client, "[FreezeTimer] The timer is already frozen.");
		return;
	}
	if (!bFreezeAction && !g_bFrozen)
	{
		ReplyToCommand(client, "[FreezeTimer] The timer isn't frozen.");
		return;
	}

	char steamId[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
	{
		ReplyToCommand(client, "[FreezeTimer] Couldn't verify your SteamID.");
		return;
	}

	bool blocked;
	if (g_smBlacklist.GetValue(steamId, blocked))
	{
		ReplyToCommand(client, "[FreezeTimer] You've been blocked from starting freeze votes.");
		return;
	}

	int now = GetTime();
	if (now - g_iLastVoteAttempt[client] < g_iCooldown)
	{
		ReplyToCommand(client, "[FreezeTimer] Please wait before trying to start another vote.");
		return;
	}
	g_iLastVoteAttempt[client] = now;

	g_bVoteInProgress = true;
	g_bVoteIsFreeze = bFreezeAction;
	g_iVoteYes = 0;
	g_iVoteNo = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bClientVoted[i] = false;
	}

	char question[64];
	FormatEx(question, sizeof(question), "%s time left?", bFreezeAction ? "Freeze" : "Unfreeze");

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			Menu menu = new Menu(MenuHandler_FreezeVote);
			menu.SetTitle(question);
			menu.AddItem("yes", "Yes");
			menu.AddItem("no", "No");
			menu.AddItem("novote", "No vote");
			menu.ExitButton = false;
			menu.Display(i, g_iVoteDuration);
		}
	}

	PrintToChatAll("[FreezeTimer] %N started a vote to %s the timer! Check your menu.",
		client, bFreezeAction ? "freeze" : "unfreeze");

	g_hVoteEndTimer = CreateTimer(float(g_iVoteDuration) + 1.0, Timer_EndVote);
}

public int MenuHandler_FreezeVote(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, sizeof(info));

		if (!g_bClientVoted[param1])
		{
			g_bClientVoted[param1] = true;
			if (StrEqual(info, "yes"))
			{
				g_iVoteYes++;
			}
			else if (StrEqual(info, "no"))
			{
				g_iVoteNo++;
			}
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public Action Timer_EndVote(Handle timer)
{
	g_hVoteEndTimer = null;
	if (!g_bVoteInProgress)
	{
		return Plugin_Stop;
	}

	int total = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			total++;
		}
	}

	int required = RoundToCeil(float(total) * (g_flVotePercent / 100.0));
	if (required < 1)
	{
		required = 1;
	}

	bool bPassed = (g_iVoteYes >= required);

	if (bPassed)
	{
		if (g_bVoteIsFreeze)
		{
			DoFreeze(0, false);
		}
		else
		{
			DoUnfreeze(0, false);
		}
		PrintToChatAll("[FreezeTimer] Vote passed (%d/%d needed) — timer %s.",
			g_iVoteYes, required, g_bVoteIsFreeze ? "frozen" : "unfrozen");
	}
	else
	{
		PrintToChatAll("[FreezeTimer] Vote failed (%d yes, %d needed).", g_iVoteYes, required);
	}

	g_bVoteInProgress = false;
	return Plugin_Stop;
}

// cfgs / bl

void LoadConfig()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);

	KeyValues kv = new KeyValues("freezetimer");

	if (FileExists(path))
	{
		kv.ImportFromFile(path);
		g_flVotePercent = kv.GetFloat("vote_percent", 60.0);
		g_iVoteDuration  = kv.GetNum("vote_duration", 20);
		g_iCooldown      = kv.GetNum("cooldown", 30);
	}
	else
	{
		kv.SetFloat("vote_percent", g_flVotePercent);
		kv.SetNum("vote_duration", g_iVoteDuration);
		kv.SetNum("cooldown", g_iCooldown);
		kv.ExportToFile(path);
	}

	delete kv;
}

void LoadBlacklist()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), BLACKLIST_FILE);

	if (!FileExists(path))
	{
		return;
	}

	File file = OpenFile(path, "r");
	if (file == null)
	{
		return;
	}

	char line[64];
	while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
	{
		TrimString(line);
		if (line[0] != '\0')
		{
			g_smBlacklist.SetValue(line, true);
		}
	}

	delete file;
}

void SaveBlacklist()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), BLACKLIST_FILE);

	File file = OpenFile(path, "w");
	if (file == null)
	{
		return;
	}

	StringMapSnapshot snap = g_smBlacklist.Snapshot();
	for (int i = 0; i < snap.Length; i++)
	{
		char key[64];
		snap.GetKey(i, key, sizeof(key));
		file.WriteLine("%s", key);
	}
	delete snap;
	delete file;
}

void ReplyToClientOrChat(int client, const char[] message)
{
	if (client >= 1 && client <= MaxClients && IsClientInGame(client))
	{
		ReplyToCommand(client, message);
	}
	else
	{
		PrintToChatAll(message);
	}
}

// added notes because more people seem to be looking at my stuff (i appreciate every piece of attention my plugins get! thanks people!!)

public Action Shavit_OnKeyHintHUD(int client, int target, char[] message, int maxlength, int track, int style)
{
	if (!g_bFrozen || !g_cvFrozenLabel.BoolValue)
	{
		return Plugin_Continue;
	}

	int pos = StrContains(message, "\n");

	char buffer[256];
	if (pos == -1)
	{
		FormatEx(buffer, sizeof(buffer), "%s [FROZEN]", message);
	}
	else
	{
		char firstLine[128];
		strcopy(firstLine, sizeof(firstLine), message);
		firstLine[pos] = '\0';

		FormatEx(buffer, sizeof(buffer), "%s [FROZEN]%s", firstLine, message[pos]);
	}

	strcopy(message, maxlength, buffer);

	return Plugin_Changed;
}
