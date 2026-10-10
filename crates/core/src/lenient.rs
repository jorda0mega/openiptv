//! Serde helpers for Xtream Codes panels, which disagree on whether a number is
//! a number, a numeric string, an empty string, `false` or `null`. One odd row
//! must never fail a whole channel list, so every helper degrades to a default.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::Value;

pub fn opt_i64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => {
            let s = s.trim();
            s.parse::<i64>()
                .ok()
                .or_else(|| s.parse::<f64>().ok().map(|f| f as i64))
        }
        _ => None,
    })
}

pub fn opt_string<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::String(s) if !s.trim().is_empty() => Some(s),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    })
}

pub fn string<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    opt_string(d).map(Option::unwrap_or_default)
}

pub fn flag<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Bool(b) => b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => matches!(
            s.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "active"
        ),
        _ => false,
    })
}

pub fn string_list<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Array(items) => items
            .into_iter()
            .filter_map(|v| match v {
                Value::String(s) => Some(s),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            })
            .collect(),
        Value::String(s) => s
            .split(',')
            .map(|p| p.trim().to_owned())
            .filter(|p| !p.is_empty())
            .collect(),
        _ => Vec::new(),
    })
}

/// Panels return `[]`, `{}`, `false` or `null` for "nothing"; rows that fail
/// to decode are dropped instead of failing the list.
pub fn seq<'de, D: Deserializer<'de>, T: DeserializeOwned>(d: D) -> Result<Vec<T>, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Array(items) => items
            .into_iter()
            .filter_map(|v| serde_json::from_value(v).ok())
            .collect(),
        Value::Object(map) => map
            .into_iter()
            .filter_map(|(_, v)| serde_json::from_value(v).ok())
            .collect(),
        _ => Vec::new(),
    })
}

/// Top-level variant of [`seq`] for endpoints that return a bare list.
pub fn seq_from_slice<T: DeserializeOwned>(
    body: &[u8],
    what: &'static str,
) -> crate::Result<Vec<T>> {
    let mut de = serde_json::Deserializer::from_slice(body);
    let rows = seq(&mut de).map_err(|source| crate::Error::Decode { what, source })?;
    Ok(rows)
}
