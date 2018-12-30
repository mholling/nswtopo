module NSWTopo
  module Overlay
    include Vector

    def get_features
      raise "no such file #{@path}" unless @path.exist?
      features = GPS.load @path
      features.each do |feature|
        name = feature.properties["name"]
        feature.properties.clear
        feature.properties["categories"] = [ name.to_category ] unless name.empty?
      end
      features
    rescue GPS::BadFile => error
      raise "#{error.message} not a valid GPX or KML file"
    end
  end
end
