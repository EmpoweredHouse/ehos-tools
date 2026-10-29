defmodule EhosDesign.Browser.Layout do
  @moduledoc false
  # The browser test's page: the design system's stylesheets as they ship, and the script.

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>ehos_design</title>
        <link rel="stylesheet" href="/css/colors_and_type.css" />
        <link rel="stylesheet" href="/css/components/listbox.css" />
        <script defer src="/js/app.js">
        </script>
      </head>
      <body style="background: var(--canvas); padding: 24px; max-width: 480px;">
        {@inner_content}
      </body>
    </html>
    """
  end
end
