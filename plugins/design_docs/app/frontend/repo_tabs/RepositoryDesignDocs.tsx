import { useParams } from "react-router-dom"
import { DesignDocsSurface } from "../components/DesignDocsSurface"

export default function RepositoryDesignDocsRoute() {
  const params = useParams()
  return <DesignDocsSurface mode="repository" repositoryId={params.repositoryId || ""} />
}
