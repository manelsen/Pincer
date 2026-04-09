{application,pincer_openai_compat,
             [{modules,['Elixir.Pincer.LLM.Providers.OpenAICompat',
                        'Elixir.PincerOpenaiCompat']},
              {optional_applications,[]},
              {applications,[kernel,stdlib,elixir,logger,pincer_ports,req,
                             jason]},
              {description,"OpenAI-compatible LLM provider adapter for the Pincer AI agent framework"},
              {registered,[]},
              {vsn,"0.1.0"}]}.
