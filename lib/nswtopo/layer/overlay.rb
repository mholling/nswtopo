module NSWTopo
  module Overlay
    include Vector

    def get_features
      features = GPS.load @path
      features.each do |feature|
        name = feature["name"]
        feature.clear
        feature["categories"] = [categorise(name)] unless name.empty?
      end
      features
    end
  end
end
