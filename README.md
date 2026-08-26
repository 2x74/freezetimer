# freezetimer
Freezes the timer in shavittimer servers

## Usage (Cvars)
### Player commands
`/freezetimer` - Freezes the timer; starts a vote when used by non-admins
`/ft` - Alias for `/freezetimer`
`/unfreezetimer` - Unfreezes the timer, same exact logic as `/freezetimer`
`/uft` - Alias for `/unfreezetimer`
### Admin commands
`/antifreeze` - Blocks a user from using freezetimer commands
`/allowfreeze` - Removes said block from a user
`/frozenlabel` - Toggles whether the [FROZEN] label is next to the timelimit (Time left text on the right)
`/freezetimer_reload` - Seldom used, only for debugging for whatever reason (literally just reloads the plugin)

## Config
The config for freezetimer is saved at `~/<CSS-DIR>/cstrike/addons/sourcemod/configs/freezetimer.cfg`
`vote_percent` - The percentage of people in the server needed to vote yes to freeze/unfreeze the timer (default is 60%)
`vote_duration` - The length the vote actually runs for (default is 20s)
`cooldown` - the time set between votes; used to prevent spamming and such (default is 30s)
