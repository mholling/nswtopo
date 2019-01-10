module NSWTopo
  module Overlay
    include Vector

    def get_features
      features = GPS.load @path
      features.each do |feature|
        name = feature.properties["name"]
        feature.properties.clear
        feature.properties["categories"] = [ name.to_category ] unless name.empty?
      end
      features
    end
  end
end
