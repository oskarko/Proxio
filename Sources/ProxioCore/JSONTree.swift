import Foundation

/// A parsed JSON value laid out for an outline view.
public struct JSONNode: Identifiable, Sendable {
    public let id = UUID()
    public let key: String?
    public let summary: String
    public let children: [JSONNode]?

    public static func parse(_ data: Data) -> JSONNode? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return node(key: nil, object)
    }

    static func node(key: String?, _ value: Any) -> JSONNode {
        if let dict = value as? [String: Any] {
            let kids = dict.keys.sorted().map { node(key: $0, dict[$0]!) }
            return JSONNode(key: key, summary: "{\(dict.count)}", children: kids)
        }
        if let array = value as? [Any] {
            let kids = array.enumerated().map { node(key: "[\($0.offset)]", $0.element) }
            return JSONNode(key: key, summary: "[\(array.count)]", children: kids)
        }
        if value is NSNull { return JSONNode(key: key, summary: "null", children: nil) }
        if let n = value as? NSNumber {
            let text = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            return JSONNode(key: key, summary: text, children: nil)
        }
        return JSONNode(key: key, summary: "\"\(value)\"", children: nil)
    }
}

/// A GraphQL operation found in a request body.
public struct GraphQLOperation: Sendable, Equatable {
    public var name: String?
    public var query: String
    public var variables: String?
}

public enum GraphQLParser {
    /// Operations in a JSON body (`{query, variables, operationName}` or an array of those).
    public static func operations(in body: Data) -> [GraphQLOperation] {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }
        let items = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { item in
            guard let query = item["query"] as? String else { return nil }
            var vars: String?
            if let v = item["variables"], !(v is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) {
                vars = String(data: data, encoding: .utf8)
            }
            return GraphQLOperation(name: item["operationName"] as? String ?? inferredName(query), query: query, variables: vars)
        }
    }

    /// `query Foo(...)` → "Foo".
    static func inferredName(_ query: String) -> String? {
        let words = query.split(whereSeparator: { " \n\t\r({".contains($0) })
        guard words.count >= 2, ["query", "mutation", "subscription"].contains(String(words[0])) else { return nil }
        return String(words[1])
    }
}
