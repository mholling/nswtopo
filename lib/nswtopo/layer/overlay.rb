module NSWTopo
  module Overlay
    include Vector

    DEFAULTS = YAML.load <<~YAML
      stroke: black
      stroke-width: 0.4
      fill: black
      fill-opacity: 0.3
    YAML

    def get_features
      GPS.load(@path).each do |feature|
        styles, folder, name = feature.values_at "styles", "folder", "name"
        feature.clear
        categories = [folder, name].compact.reject(&:empty?).map(&method(:categorise))
        if styles
          feature["category"] = categories << feature.object_id
          @params[categories.join(?\s)] = styles
        else
          feature["category"] = categories if categories.any?
        end
      end
    end
  end
end
