# Managing people

`ehosctl people` lists, invites, renames, disables and enables the people of the company, resets
their passwords and signs out their terminals. These commands do what the people page of the
console does, through the API of EHOS. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/people-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/people-api.md)
describes the API that they use.

```sh
ehosctl people list --state invited,joined,disabled --q ada
ehosctl people show ada@example.com
ehosctl people invite alan@example.com --name "Alan Turing"
ehosctl people rename ada@example.com "Ada Lovelace"
ehosctl people disable 6f1c…
ehosctl people reset-password ada@example.com
ehosctl people sign-out ada@example.com
```

`list` and `show` need `ehos.people.read`. `invite`, `rename`, `disable`, `enable`,
`reset-password` and `sign-out` need `ehos.people.manage`. EHOS records each of these commands, as
it records the actions in the console.

## Name a person

Give the id or the email of the person. A word with an `@` is an email. `ehosctl` looks it up with
the `--q` option of `list`.

`show` looks for an email only among the invited and the joined people. A list of disabled people
needs `ehos.people.manage`, so to show a disabled person, give their id.

## List the people

`list` reads each page that EHOS gives, in the order of the email. Without `--state`, it shows the
invited and the joined people.

`--limit N` stops after `N` people. If more people match, `ehosctl` says so. With `--json`, the
output is `{"people": [...], "more": true}`.

## Invite a person

`invite` says if EHOS mailed a sign-in link to the person. `ehosctl` never shows a link, because
the API never gives one: a person who reads the link can sign in as that person.

If the installation does not send mail, give the person a link in one of these ways:

- A people manager invites the person again in the console, and gives the link to the person.
- The installation administrator runs `ehosctl server invite`. See
  [Inviting a person as the operator](server-invite.md).

## Reset the password of a person

`reset-password` makes EHOS mail the person a link that sets a new password. The link works once,
for 1 hour. The password of the person works until they set a new one. A person who has not joined
gets an invitation link instead.

- EHOS sends the link only to the person. `ehosctl` never shows it.
- If the installation does not send mail, EHOS refuses the reset.
- If the person is disabled, EHOS refuses the reset. Enable the person first.
- EHOS refuses a fourth reset of one person in one hour by people managers. Each reset that EHOS
  accepts counts, also one whose answer did not arrive.
- If the mail server does not take the mail, EHOS says so. You can run the command again.
- With `--json`, the output is `{"person": {...}, "delivery": "mailed"}`.

Do not run the command again when the answer does not arrive. EHOS possibly mailed the link, and
each run mails another one. Ask the person first.

## Sign out all terminals of a person

`sign-out` signs out each terminal of a person, as the people page does when a person loses a
laptop. The person stays enabled.

- The terminals cannot renew their sign-in, so their commands stop within 10 minutes.
- A sign-in that the person started a moment before cannot finish.
- `ehosctl` says how many terminals were signed in. This can be none. With `--json`, the output is
  `{"signed_out": <count>}`.

`sign-out` needs `ehos.people.manage`, also for your own terminals. To sign out your own terminals
one at a time, run `ehosctl terminals sign-out`.

## Rename a person

`rename` with an empty name, `""`, removes the name. Only the person can change their email, in the
console.

## Set a password

No command of `ehosctl` sets or resets a password.

## Next steps

- [Signing in](login.md): sign in, and sign out your own terminals.
- [Role bindings](role-bindings.md): give a role to a person.

## Background

- [eh-os D-80](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0080-ehos-s-api-lists-people-to-ehos-people-read-and-manages-them-for-ehos-people-manage.md):
  why the API lists people and never gives a sign-in link.
