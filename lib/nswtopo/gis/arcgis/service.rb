module NSWTopo
  module ArcGIS
    class Service
      SERVICE = /^(?:MapServer|FeatureServer|ImageServer)$/

      def self.check_uri(url)
        uri = URI.parse url
        return unless URI::HTTP === uri
        return unless uri.path
        instance, (id, *) = uri.path.split(?/).slice_after(SERVICE).take(2)
        return unless SERVICE === instance&.last
        return unless !id || id =~ /^\d+$/
        return uri, instance.join(?/), id
      rescue URI::Error
      end

      def self.===(string)
        uri, service_path, id = check_uri string
        uri != nil
      end

      def initialize(url)
        uri, service_path, @id = Service.check_uri url
        raise "invalid ArcGIS server URL: %s" % url unless uri
        @connection = Connection.new uri, service_path
        @service = get_json ""

        @projection = case
        when wkt  = @service.dig("spatialReference", "wkt") then Projection.new(wkt)
        when wkid = @service.dig("spatialReference", "latestWkid") then Projection.new("EPSG:#{wkid}")
        when wkid = @service.dig("spatialReference", "wkid") then Projection.new("EPSG:#{wkid == 102100 ? 3857 : wkid}")
        else raise "no spatial reference found: #{uri}"
        end
      end

      extend Forwardable
      delegate %i[get get_json] => :@connection
      delegate :[] => :@service
      attr_reader :projection

      def layer(id: @id, **options)
        Layer.new(self, id: id, **options)
      end

      def to_s
        max_id = @service["layers"].map do |layer|
          layer["id"]
        end.max
        indents, padded = [], "%#{max_id.to_s.size}i"

        StringIO.new.tap do |io|
          io.puts "layers:"
          @service["layers"].each do |layer|
            indent = indents.pop
            io.puts "  %s%s: %s" % [indent, padded % layer["id"], layer["name"]]
            layer["subLayerIds"]&.size&.times do
              indents << "#{indent}  "
            end
          end
        end.string
      end
    end
  end
end
