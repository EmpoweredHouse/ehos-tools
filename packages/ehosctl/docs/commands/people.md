# Managing people

```sh
ehosctl people list --state invited,joined,disabled --q ada
ehosctl people show ada@example.com
ehosctl people invite alan@example.com --name "Alan Turing"
ehosctl people rename ada@example.com "Ada Lovelace"
ehosctl people disable 6f1c…
ehosctl people sign-out ada@example.com
```

`people` does what the console's people page does, through EHOS's API
([eh-os `docs/people-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/people-api.md)).
`list` and `show` need `ehos.people.read`; `invite`, `rename`, `disable`, `enable` and `sign-out`
need `ehos.people.manage`. EHOS records every one of them, as it records the console's.

- **A person** is named by their id or their email; a word with an `@` is an email, looked up
  with `list`'s `--q`. `show` finds an email among the invited and the joined only, since listing
  the disabled needs `ehos.people.manage`: show a disabled person by their id.
- **`list`** follows every page EHOS gives, ordered by email. `--limit N` stops after `N` people
  and says when more match; under `--json`, `{"people": [...], "more": true}`. `--state` defaults
  to `invited,joined`.
- **`invite`** says whether the sign-in link was mailed. It never prints a link: the API never
  gives one, since it would sign in whoever reads it as that person
  ([eh-os D-80](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0080-ehos-s-api-lists-people-to-ehos-people-read-and-manages-them-for-ehos-people-manage.md)).
  Without mail, a people manager hands one over by inviting them again in the console, and the
  operator by `ehosctl server invite` ([Inviting a person as the operator](server-invite.md)).
- **`sign-out`** signs out every terminal of a person, without disabling them, as the people page
  does when a laptop is lost: their terminals can no longer renew, so their commands stop within
  ten minutes, and a sign-in they began a moment before cannot finish. It says how many were
  signed in, which may be none; under `--json`, `{"signed_out": <count>}`. It needs
  `ehos.people.manage` even for yourself: your own terminals you sign out with `ehosctl terminals
  sign-out`.
- **`rename`** with an empty name, `""`, removes it. An email is changed only by its owner, in the
  console.
- **No command sets or resets a password.**
