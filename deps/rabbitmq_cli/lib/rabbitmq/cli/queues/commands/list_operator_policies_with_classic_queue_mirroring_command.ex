## This Source Code Form is subject to the terms of the Mozilla Public
## License, v. 2.0. If a copy of the MPL was not distributed with this
## file, You can obtain one at https://mozilla.org/MPL/2.0/.
##
## Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.

defmodule RabbitMQ.CLI.Queues.Commands.ListOperatorPoliciesWithClassicQueueMirroringCommand do
  @behaviour RabbitMQ.CLI.CommandBehaviour

  def scopes(), do: [:diagnostics, :queues]
  use RabbitMQ.CLI.Core.AcceptsDefaultSwitchesAndTimeout
  use RabbitMQ.CLI.Core.MergesNoDefaults
  use RabbitMQ.CLI.Core.AcceptsNoPositionalArguments
  use RabbitMQ.CLI.Core.RequiresRabbitAppRunning

  def run([], %{node: node_name, timeout: timeout}) do
    :rabbit_misc.rpc_call(
      node_name,
      :rabbit_mirror_queue_misc,
      :list_operator_policies_with_classic_queue_mirroring_for_cli,
      [],
      timeout
    )
  end

  use RabbitMQ.CLI.DefaultOutput

  def formatter(), do: RabbitMQ.CLI.Formatters.Table

  def usage, do: "list_operator_policies_with_classic_queue_mirroring [--no-table-headers]"

  def help_section(), do: :observability_and_health_checks

  def description() do
    "List all operator policies that enable classic queue mirroring"
  end

  def banner(_, _), do: "Listing operator policies with classic queue mirroring ..."
end
