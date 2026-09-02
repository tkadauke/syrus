import { useParams } from "react-router-dom"
import { DesignDocsSurface } from "../components/DesignDocsSurface"

export default function DesignDocsRoute() {
  const params = useParams()
  return <DesignDocsSurface mode={params.id ? "show" : "index"} />
}
