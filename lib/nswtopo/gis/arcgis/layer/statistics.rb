module NSWTopo
  module ArcGIS
    module Statistics
      def classify(*fields)
        statistics = fields.map.with_index do |name, index|
          { statisticType: "count", onStatisticField: name, outStatisticFieldName: "COUNT_#{index}" }
        end
        field_counts = get_json "#{@id}/query", **query, outStatistics: statistics.to_json, groupByFieldsForStatistics: fields.join(?,)
        field_counts["features"].map do |feature|
          [feature["attributes"].slice(*fields), feature["attributes"]["COUNT_0"]]
        end
      end
    end
  end
end
