# Inviting a person through the server

`ehosctl server invite` prints a link that signs a person in to EHOS one time. The installation
administrator uses it for the first person of a new installation. While the installation sends no
mail, it also lets in a person who forgot their password. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl server tunnel --installation acme
ehosctl server invite ada@example.com --installation acme
```

## What the command does

1. `server invite` runs the release command of EHOS, `Ehos.Release.invite/1`, in the governance
   container. It uses `kubectl exec`, through the kubeconfig that `tunnel` wrote, with the kubectl
   that EHOS pins. So a `kubectl` of asdf, or of the directory that you are in, never runs in its
   place.
2. EHOS invites the person. If the platform has no administrator yet, EHOS makes the person its
   administrator.
3. EHOS prints a link that signs the person in one time, within 15 minutes.
4. `server invite` prints what EHOS said, the link on a line of its own, and what to do with the
   link.

`server invite` needs no sign-in, no release and no passphrase.

## Invite the first person

Nobody can sign in to a new installation yet, and `ehosctl people invite` never shows a link. So
invite the first person with `server invite`.

## Let a person in again

`server invite` does not refuse a person who has joined, as the console and `people invite` do. The
link signs them in again. While the installation sends no mail, a person who forgot their password
gets back in this way. Run the command only when you know that the request comes from that person.

## Give the link to the person

The link is a password: each person who opens it signs in as that person. `server invite` says so
in a warning on stderr, before it prints the link on a line of its own.

- Give the link only to that person, in a direct message to an account that you know is theirs.
- Do not put it in a channel, a ticket or a thread that others read.
- The link works one time, for 15 minutes. A new link does not end it.

If another person possibly saw the link, disable the person, with `ehosctl people disable` or the
People page of the console. This ends each link of the person. Then enable the person and run the
command again. Nobody can disable the only administrator of the platform: that person must open the
link at once, which uses it.

## Which addresses EHOS accepts

The address must be one that EHOS accepts: one `@` with text on each side, no space, comma or
semicolon, and at most 160 characters.

`server invite` refuses more than EHOS does: invalid UTF-8, control and format characters, line and
paragraph separators, and the spaces of Unicode, such as U+00A0. A terminal acts on these
characters, or they hide in a pasted address. For such an address, the command exits 2 before
anything runs.

The address reaches EHOS as an Elixir string, written by `inspect/2`. `server invite` parses it back
to check that it is one call with that exact string. So EHOS invites an address that holds a quote,
a backslash or `#{` as it is, and the address runs no code.

## What can go wrong

- If EHOS refuses, as for a disabled person, `server invite` shows the refusal of EHOS and exits 1.
- If `kubectl` fails for another reason, `server invite` shows what it printed, with the token of a
  sign-in link hidden. It asks if the tunnel is open.
- If `kubectl` does not finish within 2 minutes, `server invite` stops it. EHOS can still have
  invited the person. Run the command again to get a link.
- If `kubectl` fails after EHOS printed the link, `server invite` still prints the link. It says
  that the line about the administrator can be missing.

## Next steps

- [Sign in with ehosctl](login.md)
- [Manage people](people.md)
