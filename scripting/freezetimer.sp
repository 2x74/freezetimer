#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define CONFIG_FILE    "configs/freezetimer.cfg"
#define BLACKLIST_FILE "configs/freezetimer_blacklist.txt"
#define VOTE_ACTIONS   view_as<MenuAction>(MenuAction_End|MenuAction_VoteCancel)

ConVar g_cvFrozenLabel;
ConVar g_cvTimeLimit;

float g_flVotePercent = 60.0;
int   g_iVoteDuration  = 20;
int   g_iCooldown      = 30;
char  g_sAdminFlag[24] = "b";
int   g_iAdminFlagBits = ADMFLAG_GENERIC;

bool   g_bFrozen;
int    g_iFrozenAtTime;
float  g_flTimeLimitAtFreeze;
Handle g_hHoldTimer;

bool   g_bVoteIsFreeze;
int    g_iLastVoteAttempt[MAXPLAYERS + 1];
bool   g_bBlacklisted[MAXPLAYERS + 1];

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
	RegAdminCmd("sm_freezetimer_check", Cmd_Check, ADMFLAG_GENERIC,
		"sm_freezetimer_check <#userid|name> - explain why a player gets an instant freeze or a vote.");

	g_smBlacklist = new StringMap();
	LoadConfig();
	LoadBlacklist();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			CacheBlacklistState(i);
		}
	}

	g_hFwdStateChanged = CreateGlobalForward("FreezeTimer_OnStateChanged", ET_Ignore, Param_Cell);
}

public void OnMapEnd()
{
	g_hHoldTimer = null;
	g_bFrozen = false;
	g_iFrozenAtTime = 0;
	g_flTimeLimitAtFreeze = 0.0;
	g_bVoteIsFreeze = false;

	for (int i = 1; i <= MAXPLAYERS; i++)
	{
		g_iLastVoteAttempt[i] = 0;
	}
}

public void OnClientPutInServer(int client)
{
	g_iLastVoteAttempt[client] = 0;
	g_bBlacklisted[client] = false;
}

public void OnClientDisconnect(int client)
{
	g_iLastVoteAttempt[client] = 0;
	g_bBlacklisted[client] = false;
}

public void OnClientPostAdminCheck(int client)
{
	CacheBlacklistState(client);
}

void CacheBlacklistState(int client)
{
	g_bBlacklisted[client] = false;

	if (IsFakeClient(client))
	{
		return;
	}

	char steamId[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
	{
		return;
	}

	bool blocked;
	g_bBlacklisted[client] = (g_smBlacklist.GetValue(steamId, blocked) && blocked);
}

// cmds

public Action Cmd_FreezeTimer(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[FreezeTimer] Use rcon/sm_frozenlabel style commands from console; freezing requires a client.");
		return Plugin_Handled;
	}

	if (HasInstantAccess(client))
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

	if (HasInstantAccess(client))
	{
		DoUnfreeze(client, true);
	}
	else
	{
		TryStartVote(client, false);
	}
	return Plugin_Handled;
}

bool HasInstantAccess(int client)
{
	if (client == 0)
	{
		return true;
	}

	return CheckCommandAccess(client, "freezetimer_instant", g_iAdminFlagBits, false);
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
	g_bBlacklisted[target] = true;

	char name[MAX_NAME_LENGTH];
	GetClientName(target, name, sizeof(name));
	char actor[MAX_NAME_LENGTH];
	GetActorName(client, actor, sizeof(actor));
	PrintToChatAll("[FreezeTimer] %s blocked %s from starting freeze votes.", actor, name);
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
	g_bBlacklisted[target] = false;

	char name[MAX_NAME_LENGTH];
	GetClientName(target, name, sizeof(name));
	char actor[MAX_NAME_LENGTH];
	GetActorName(client, actor, sizeof(actor));
	PrintToChatAll("[FreezeTimer] %s unblocked %s from starting freeze votes.", actor, name);
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

	char actor[MAX_NAME_LENGTH];
	GetActorName(client, actor, sizeof(actor));
	PrintToChatAll("[FreezeTimer] %s %s the [FROZEN] hint.", actor, val ? "enabled" : "disabled");
	return Plugin_Handled;
}

public Action Cmd_Check(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: sm_freezetimer_check <#userid|name>");
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
		strcopy(steamId, sizeof(steamId), "(unavailable)");
	}

	char flagText[40];
	FlagBitsToText(GetUserFlagBits(target), flagText, sizeof(flagText));

	int wait = g_iCooldown - (GetTime() - g_iLastVoteAttempt[target]);
	if (wait < 0)
	{
		wait = 0;
	}

	ReplyToCommand(client, "[FreezeTimer] %N - steamid %s, bot: %s", target, steamId,
		IsFakeClient(target) ? "YES" : "no");
	ReplyToCommand(client, "[FreezeTimer]   flags: %s | required: \"%s\" (bits %d)", flagText, g_sAdminFlag, g_iAdminFlagBits);
	ReplyToCommand(client, "[FreezeTimer]   branch: %s", HasInstantAccess(target) ? "INSTANT (skips the vote)" : "VOTE");
	ReplyToCommand(client, "[FreezeTimer]   blacklisted: %s | cooldown: %ds", g_bBlacklisted[target] ? "YES" : "no", wait);
	ReplyToCommand(client, "[FreezeTimer]   vote allowed right now: %s", IsNewVoteAllowed() ? "yes" : "no (vote running, or sm_vote_delay)");

	if (IsFakeClient(target))
	{
		ReplyToCommand(client, "[FreezeTimer]   bots cannot receive votes and never see replies - test with a real client.");
	}

	return Plugin_Handled;
}

void FlagBitsToText(int bits, char[] buffer, int maxlen)
{
	AdminFlag flags[AdminFlags_TOTAL];
	int count = FlagBitsToArray(bits, flags, sizeof(flags));

	int len = 0;
	for (int i = 0; i < count && len < maxlen - 1; i++)
	{
		int c;
		if (FindFlagChar(flags[i], c))
		{
			buffer[len++] = c;
		}
	}
	buffer[len] = '\0';

	if (len == 0)
	{
		strcopy(buffer, maxlen, "(none)");
	}
}

void GetActorName(int client, char[] buffer, int maxlen)
{
	if (client >= 1 && client <= MaxClients && IsClientInGame(client))
	{
		GetClientName(client, buffer, maxlen);
	}
	else
	{
		strcopy(buffer, maxlen, "Console");
	}
}

public Action Cmd_ReloadConfig(int client, int args)
{
	LoadConfig();
	ReplyToCommand(client, "[FreezeTimer] Config reloaded (vote_percent %.1f, vote_duration %d, cooldown %d, admin_flag \"%s\").",
		g_flVotePercent, g_iVoteDuration, g_iCooldown, g_sAdminFlag);
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

	if (g_cvTimeLimit == null || g_cvTimeLimit.FloatValue <= 0.0)
	{
		ReplyToClientOrChat(client, "[FreezeTimer] mp_timelimit isn't set, so there's nothing to hold.");
		return;
	}

	g_flTimeLimitAtFreeze = g_cvTimeLimit.FloatValue;
	g_iFrozenAtTime = GetTime();
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

	if (g_cvTimeLimit == null)
	{
		return Plugin_Continue;
	}

	int flags = g_cvTimeLimit.Flags;
	g_cvTimeLimit.Flags = flags & ~FCVAR_NOTIFY;

	g_cvTimeLimit.FloatValue = g_flTimeLimitAtFreeze + float(GetTime() - g_iFrozenAtTime) / 60.0;

	g_cvTimeLimit.Flags = flags;

	return Plugin_Continue;
}

// yes i made a democratic plugin i'm so proud of myself

void TryStartVote(int client, bool bFreezeAction)
{
	if (!IsNewVoteAllowed())
	{
		int delay = CheckVoteDelay();
		if (delay > 0)
		{
			ReplyToCommand(client, "[FreezeTimer] Please wait %d more second%s before starting a vote.",
				delay, delay == 1 ? "" : "s");
		}
		else
		{
			ReplyToCommand(client, "[FreezeTimer] A vote is already in progress.");
		}
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

	if (g_bBlacklisted[client])
	{
		ReplyToCommand(client, "[FreezeTimer] You've been blocked from starting freeze votes.");
		return;
	}

	int now = GetTime();
	int wait = g_iCooldown - (now - g_iLastVoteAttempt[client]);
	if (wait > 0)
	{
		ReplyToCommand(client, "[FreezeTimer] Please wait %d more second%s before trying to start another vote.",
			wait, wait == 1 ? "" : "s");
		return;
	}

	Menu menu = new Menu(MenuHandler_FreezeVote, VOTE_ACTIONS);
	menu.SetTitle("%s time left?", bFreezeAction ? "Freeze" : "Unfreeze");
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.AddItem("novote", "No vote");
	menu.ExitButton = false;
	SetVoteResultCallback(menu, Handler_VoteResults);

	if (!menu.DisplayVoteToAll(g_iVoteDuration))
	{
		delete menu;
		ReplyToCommand(client, "[FreezeTimer] Couldn't start the vote right now, try again shortly.");
		return;
	}

	g_bVoteIsFreeze = bFreezeAction;
	g_iLastVoteAttempt[client] = now;

	PrintToChatAll("[FreezeTimer] %N started a vote to %s the map timer.",
		client, bFreezeAction ? "freeze" : "unfreeze");
}

public int MenuHandler_FreezeVote(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_End:
		{
			delete menu;
		}

		case MenuAction_VoteCancel:
		{
			if (param1 == VoteCancel_NoVotes)
			{
				PrintToChatAll("[FreezeTimer] Vote failed - nobody voted.");
			}
			else
			{
				PrintToChatAll("[FreezeTimer] Vote cancelled.");
			}
		}
	}

	return 0;
}

public void Handler_VoteResults(Menu menu, int num_votes, int num_clients,
	const int[][] client_info, int num_items, const int[][] item_info)
{
	int yesVotes, noVotes;

	for (int i = 0; i < num_items; i++)
	{
		char info[16];
		menu.GetItem(item_info[i][VOTEINFO_ITEM_INDEX], info, sizeof(info));

		if (StrEqual(info, "yes"))
		{
			yesVotes = item_info[i][VOTEINFO_ITEM_VOTES];
		}
		else if (StrEqual(info, "no"))
		{
			noVotes = item_info[i][VOTEINFO_ITEM_VOTES];
		}
	}

	int decided = yesVotes + noVotes;
	float percent = (decided > 0) ? (100.0 * float(yesVotes) / float(decided)) : 0.0;

	if (decided <= 0)
	{
		PrintToChatAll("[FreezeTimer] Vote failed - nobody picked Yes or No.");
		return;
	}

	if (percent < g_flVotePercent)
	{
		PrintToChatAll("[FreezeTimer] Vote failed - %d/%d yes (%.0f%%, needed %.0f%%).",
			yesVotes, decided, percent, g_flVotePercent);
		return;
	}

	bool bWanted = g_bVoteIsFreeze;

	if (bWanted == g_bFrozen)
	{
		PrintToChatAll("[FreezeTimer] Vote passed - %d/%d yes (%.0f%%) - but the timer is already %s.",
			yesVotes, decided, percent, g_bFrozen ? "frozen" : "unfrozen");
		return;
	}

	if (bWanted)
	{
		DoFreeze(0, false);
	}
	else
	{
		DoUnfreeze(0, false);
	}

	if (g_bFrozen == bWanted)
	{
		PrintToChatAll("[FreezeTimer] Vote passed - %d/%d yes (%.0f%%) - timer %s.",
			yesVotes, decided, percent, bWanted ? "frozen" : "unfrozen");
	}
	else
	{
		PrintToChatAll("[FreezeTimer] Vote passed - %d/%d yes (%.0f%%) - but the timer couldn't be %s.",
			yesVotes, decided, percent, bWanted ? "frozen" : "unfrozen");
	}
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
		kv.GetString("admin_flag", g_sAdminFlag, sizeof(g_sAdminFlag), "b");
	}
	else
	{
		kv.SetFloat("vote_percent", g_flVotePercent);
		kv.SetNum("vote_duration", g_iVoteDuration);
		kv.SetNum("cooldown", g_iCooldown);
		kv.SetString("admin_flag", g_sAdminFlag);
		kv.ExportToFile(path);
	}

	delete kv;

	if (g_flVotePercent < 1.0)
	{
		g_flVotePercent = 1.0;
	}
	else if (g_flVotePercent > 100.0)
	{
		g_flVotePercent = 100.0;
	}

	if (g_iVoteDuration < 5)
	{
		g_iVoteDuration = 5;
	}
	else if (g_iVoteDuration > 60)
	{
		g_iVoteDuration = 60;
	}

	if (g_iCooldown < 0)
	{
		g_iCooldown = 0;
	}

	TrimString(g_sAdminFlag);
	g_iAdminFlagBits = (g_sAdminFlag[0] != '\0') ? ReadFlagString(g_sAdminFlag) : 0;

	if (g_iAdminFlagBits == 0)
	{
		LogError("[FreezeTimer] admin_flag \"%s\" resolves to no flags, which would grant everyone an instant freeze. Falling back to \"b\".", g_sAdminFlag);
		strcopy(g_sAdminFlag, sizeof(g_sAdminFlag), "b");
		g_iAdminFlagBits = ADMFLAG_GENERIC;
	}
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
		ReplyToCommand(client, "%s", message);
	}
	else
	{
		PrintToChatAll("%s", message);
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
