metadata    :name        => "delegate",
            :description => "Choria CLI based delegated discovery",
            :author      => "R.I.Pienaar <rip@devco.net>",
            :license     => "Apache 2.0",
            :version     => "0.1",
            :url         => "https://choria.io/",
            :timeout     => 2

discovery do
    capabilities [:classes, :facts, :identity, :agents, :compound]
end


