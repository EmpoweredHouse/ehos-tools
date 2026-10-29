# Inviting a person as the operator

```sh
ehosctl server tunnel --installation acme
ehosctl server invite ada@example.com --installation acme
```

`server invite` runs EHOS's release command, `Ehos.Release.invite/1`, in the governance
container, with `kubectl exec` through the kubeconfig `tunnel` wrote and the kubectl EHOS pins
(T-13), so a `kubectl` of asdf's or of the directory you stand in never runs in its place. EHOS
invites the person, makes them the platform's administrator when nobody is yet, and prints the
link that signs them in once, within 15 minutes; `server invite` prints what EHOS said, the link
on a line of its own, and what to do with it. It needs no sign-in, no release and no passphrase.

- **The first person** of a new installation is invited this way: nobody can sign in yet, and
  `ehosctl people invite` never shows a link.
- **A person who has joined** is not refused, as the console and `people invite` refuse them:
  the link signs them in again. While the installation sends no mail, this is how one who forgot
  their password gets back in. Run it only once you know the request comes from them.
- **The link is a password**: whoever opens it is signed in as that person. Give it to them
  alone, in a direct message to an account you know is theirs, never in a channel, a ticket or a
  thread others read. It works once, until it is used or its 15 minutes pass, and a new one does
  not end it. If anyone else may have seen it, disable the person (`ehosctl people disable`, or
  the console's People), which ends every link they hold, then enable them and run the command
  again. The platform's only administrator cannot be disabled: they open their link at once,
  which uses it up.
- **The address** must be one EHOS takes, one `@` with something on each side and no space, comma
  or semicolon, at most 160 characters. It refuses more than EHOS does: invalid UTF-8, control
  and format characters, line and paragraph separators, and Unicode's spaces, such as U+00A0,
  which a terminal acts on or which hide in a pasted address; another exits 2 before anything
  runs. It reaches EHOS as
  an Elixir string, written by `inspect/2` and parsed back to check it is that one call with that
  very string, so an address that holds a quote, a backslash or `#{` is invited as it is and runs
  no code.
- A refusal of EHOS's, as for a disabled person, is said in its own words, and exits 1. Any other
  failure of `kubectl` is said as it printed it, with a sign-in link's token hidden, and asks
  whether the tunnel is open; one that does not finish within two minutes is stopped, though EHOS
  may still have invited the person, and running it again gives a link. A `kubectl` that fails
  after EHOS printed the link still prints it, and says that EHOS's administrator line may be
  missing.
