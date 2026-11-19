defmodule Ehosctl.PlatformReportTest do
  use ExUnit.Case, async: true

  alias Ehosctl.Output
  alias Ehosctl.PlatformReport
  alias EhosPlatform.Report
  alias EhosPlatform.Secret

  doctest Ehosctl.PlatformReport

  @share "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#share-an-installation-with-another-installation-administrator"

  test "renders a new secret as its labelled value and a warning for the keepers a person acts for" do
    report = %Report{
      outcome: "The tunnel is open.",
      values: [{"Address", "203.0.113.10"}],
      secrets: [
        %Secret{kind: :state_passphrase, place: "EHOS_STATE_PASSPHRASE", new?: true},
        %Secret{kind: :kubeconfig, place: "/home/a/.ehos/office/kubeconfig", new?: true},
        %Secret{kind: :invitation_link, place: "on the screen only", new?: true},
        %Secret{
          kind: :external_database_role,
          place: "ehos-data/ehos-external-ledger",
          new?: true,
          read_from: "ledger.password"
        },
        %Secret{kind: :smtp_password, place: "ehos-system/ehos-smtp", new?: true},
        %Secret{kind: :data_session_password, place: "/tmp/s/.pgpass", new?: true},
        %Secret{kind: :ca_certificate, place: "/home/a/.ehos/office/ca.crt", new?: true}
      ],
      next: ["kubectl get nodes"]
    }

    assert text(report) ==
             """
             ✓ The tunnel is open.
               Address            203.0.113.10
               State passphrase   EHOS_STATE_PASSPHRASE
               Kubeconfig         /home/a/.ehos/office/kubeconfig
               Link               on the screen only
               Managing role      ehos-data/ehos-external-ledger
               SMTP password      ehos-system/ehos-smtp
               Password           /tmp/s/.pgpass
               CA                 /home/a/.ehos/office/ca.crt

             ! Without the state passphrase, ehosctl cannot change or remove the server.
               Keep it in the password manager that the installation administrators share.
               How: #{@share}

             ! The kubeconfig gives administrator access to the cluster.
               Keep it to yourself. Do not share it. Do not copy it: ehosctl server tunnel writes it again.

             ! The link is a password: it signs in as that person one time, within 15 minutes.
               Give it only to that person.

             ! With the password of the managing role, a person can manage that database.
               The cluster now keeps a copy of the value in ledger.password. The file is yours to keep or remove.

             Next:
               kubectl get nodes\
             """
  end

  test "renders a secret the run did not change as its labelled value alone" do
    report = %Report{
      outcome: "The tunnel is open.",
      secrets: [
        %Secret{kind: :state_passphrase, place: "EHOS_STATE_PASSPHRASE"},
        %Secret{kind: :kubeconfig, place: "/home/a/.ehos/office/kubeconfig"}
      ]
    }

    assert text(report) ==
             """
             ✓ The tunnel is open.
               State passphrase   EHOS_STATE_PASSPHRASE
               Kubeconfig         /home/a/.ehos/office/kubeconfig\
             """
  end

  test "renders a report without secrets as before" do
    assert text(%Report{outcome: "Nothing to do.", ending: :unchanged}) == "· Nothing to do."
  end

  defp text(report),
    do: report |> PlatformReport.text() |> Output.render(false) |> IO.chardata_to_string()
end
