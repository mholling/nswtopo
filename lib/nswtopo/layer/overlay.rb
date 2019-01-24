module NSWTopo
  module Overlay
    include Vector

    GPX_STYLES = YAML.load <<~YAML
      stroke: black
      stroke-width: 0.4
    YAML

    def get_features
      GPS.load(@path).each do |feature|
        styles, folder, name = feature.values_at "styles", "folder", "name"
        styles ||= GPX_STYLES

        categories = [folder, name].compact.reject(&:empty?).map(&method(:categorise))
        keys = styles.keys - params_for(categories.to_set).keys
        styles = styles.slice *keys

        feature.clear
        feature["category"] = categories << feature.object_id
        @params[categories.join(?\s)] = styles if styles.any?
      end
    end
  end
end
