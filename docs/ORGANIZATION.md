# Organising the workspace

A starting template, not a prescription. Adapt it; the value is in having
decided the structure deliberately rather than letting it accrete.

## First half hour

1. **Create the administrator account immediately** after the first start.
   Until one exists, the setup wizard is open to whoever reaches the server
   first. This is the single largest exposure window in the whole install.
2. Admin → Settings → General: set **Site Name** and confirm **Site URL**
   matches `RC_ROOT_URL` exactly.
3. Admin → Settings → Accounts: turn **Registration** to `Disabled` or
   `Invite only` unless you genuinely want open signup.
4. Admin → Settings → Accounts → Registration: restrict **Allowed domains** if
   you use email signup.
5. Create the channels below before inviting anyone, so the first people to
   arrive find a structured workspace instead of an empty one.

## Channel structure

Two axes: who can see it, and what it is for.

| Type | Visibility | Use for |
|---|---|---|
| Public channel | Anyone on the server can find and join | Default. Most things. |
| Private channel | Invite only, not discoverable | Genuinely restricted material |
| Team | A group of channels with shared membership | A department with several topics |
| Discussion | A threaded side-channel off a parent | Keeping a tangent out of the main flow |

**Default to public.** Private channels fragment knowledge and create the
impression that decisions happen where most people cannot see them. Reserve
them for material that is actually sensitive.

A workable starting set:

```
#announcements       read-only for most; leadership posts, everyone reads
#general             everything that does not fit elsewhere
#help                questions about tools and access
#random              the non-work channel, which will exist anyway
```

Then one team per department, each with its own channels:

```
Team: engineering
  #engineering             general
  #engineering-deploys     automated notifications
  #engineering-incidents   created per incident, archived after

Team: support
  #support
  #support-escalations
```

Name channels with a consistent prefix per team. It makes the sidebar
searchable once there are more than about twenty.

## Roles

Rocket.Chat ships with these; most workspaces need no more.

| Role | Grant to | Can |
|---|---|---|
| **admin** | One or two people | Everything, including settings and user deletion |
| **owner** | Whoever created a channel | Manage that channel, its topic and members |
| **moderator** | Trusted members of a busy channel | Delete messages, mute users in that channel |
| **user** | Everyone | Post, create channels, upload |
| **bot** | Integrations | API access, no interactive login |
| **guest** | External collaborators | Only the channels they are added to |

**Keep admin to the minimum.** An admin can read every private channel, export
every message, and delete accounts. Two is a good number: one fewer risks
lockout, more than that dilutes accountability.

## Permissions worth changing

Admin → Permissions. The defaults are permissive by design.

| Permission | Default | Consider |
|---|---|---|
| `delete-c` / `delete-p` | user | Restrict to admin. Deletion is permanent and there is no undo short of a restore. |
| `create-c` | user | Leave open. Restricting channel creation pushes conversation into DMs, which is worse. |
| `mention-all` | user | Restrict on large servers, or `@all` becomes a recurring irritation. |
| `view-full-other-user-info` | admin | Leave as is. |
| `snippet-message` | owner | Leave as is. |

Restricting deletion is the one that matters. The rest is taste.

## Onboarding a new person

```
[ ] Create the account, or send an invite
[ ] Add them to the team for their department
[ ] Confirm they can sign in on desktop and on their phone
[ ] Point them at the channel list and say which are the important ones
[ ] Share the connection instructions (docs/MOBILE-SETUP.md)
[ ] For local-tls: send the CA certificate and its install steps, and tell
    them the mobile app will not connect until that is done
```

That last item generates the most confusion in a local-tls deployment, because
the failure looks like a broken app rather than a missing certificate.

## Retention

Admin → Retention Policy. Off by default, which means messages and files
accumulate forever and the disk fills eventually.

Consider: no expiry on `#announcements`, something long on team channels, and
something short on `#random` and direct messages. Enabling file deletion
alongside message deletion is what actually reclaims space — deleting the
message alone leaves the object in MinIO.

Retention deletion is permanent and is not reversible from a running instance.
Decide before turning it on, and confirm backups are working first.

## Conventions worth stating explicitly

Written down once, these prevent a great deal of low-grade friction:

- Use threads for replies to a specific message, not for new topics
- `@here` for people currently online, `@all` almost never
- Channel topic says what the channel is for; keep it current
- Archive channels rather than deleting them — deletion loses the history
- If a decision is made in a DM, restate it in the relevant channel
