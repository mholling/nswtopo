module NSWTopo
  def inspect(url_or_path, **options)
    case url_or_path
    when ArcGIS::Service
      service = ArcGIS::Service.new(url_or_path)
      puts begin
        service.layer(**options)
      rescue ArcGIS::Layer::NoLayerError
        options.each do |flag, value|
          raise OptionParser::InvalidOption, "--#{flag} requires a layer name"
        end
        service
      end.to_s
    when Shapefile
      raise "TODO: not implemented"
    end
  end
end
